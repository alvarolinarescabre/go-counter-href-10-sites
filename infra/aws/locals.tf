locals {

  # General Information
  name = "${var.project_name}-${var.environment}"

  # EKS Cluster Information
  name_cluster     = "${local.name}-cluster"
  cluster_version  = var.cluster_version
  ami_type         = "AL2023_x86_64_STANDARD"
  node_groups_name = "${local.name}-ng"

  # Karpenter discovers the subnets and the security group it should attach
  # provisioned nodes to by tag, not by ID -- these are the values its
  # EC2NodeClass selectors match on (08-karpenter.tf). The same value tags the
  # private subnets (01-vpc.tf) and the node security group (02-eks.tf).
  karpenter_discovery_tag = local.name_cluster
  karpenter_node_pool     = "default"
  karpenter_node_class    = "default"

  # Human cluster access (10-cluster-access.tf)
  #
  # Short keys map to the AWS-managed EKS access policies. These are AWS's own
  # ARNs, not IAM policies -- they live in the `eks::aws:cluster-access-policy/`
  # namespace and mean nothing except attached to an access entry.
  eks_access_policy_arns = {
    "cluster-admin" = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    "admin"         = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
    "admin-view"    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"
    "edit"          = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
    "view"          = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  }

  # Identity Center provisions its roles under a path
  # (/aws-reserved/sso.amazonaws.com/<region>/), and an EKS access entry must
  # name the role WITHOUT it -- a path-carrying ARN either fails to match the
  # principal at authentication time or is silently normalised, depending on the
  # API surface. Rebuilding the ARN from the bare role name avoids the question
  # entirely.
  sso_role_arns = {
    for k, d in data.aws_iam_roles.sso_permission_sets :
    k => "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${regex("[^/]+$", one(d.arns))}"
  }

  sso_access_entries = {
    for k, v in var.sso_access_permission_sets : "sso-${k}" => {
      principal_arn = local.sso_role_arns[k]

      policy_associations = {
        (v.access_policy) = {
          policy_arn = local.eks_access_policy_arns[v.access_policy]
          # Both branches have to produce the SAME object type -- a
          # conditional whose arms differ in their attributes is a plan-time
          # error, not a null. Hence `namespaces` always present, null for a
          # cluster-scoped grant; the EKS module declares it optional and
          # passes it through as null.
          access_scope = {
            type       = v.namespaces == null ? "cluster" : "namespace"
            namespaces = v.namespaces
          }
        }
      }
    }
  }

  break_glass_trusted_principals = length(var.break_glass_trusted_principals) > 0 ? var.break_glass_trusted_principals : [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  ]

  break_glass_access_entries = var.break_glass_role_enabled ? {
    break-glass = {
      principal_arn = aws_iam_role.break_glass[0].arn

      policy_associations = {
        cluster-admin = {
          policy_arn   = local.eks_access_policy_arns["cluster-admin"]
          access_scope = { type = "cluster" }
        }
      }
    }
  } : {}

  # VPC Information
  name_vpc        = "${local.name}-vpc"
  cidr            = var.vpc_cidr
  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  # Argo CD kgateway route (06-argocd-ingress.tf)
  # A dedicated Gateway always lives in the Argo CD namespace under a fixed
  # name; otherwise the route points at whatever pre-existing Gateway the
  # variables name.
  argocd_gateway_name      = var.argocd_gateway_create ? "argocd-gateway" : var.argocd_gateway_name
  argocd_gateway_namespace = var.argocd_gateway_create ? var.argocd_namespace : var.argocd_gateway_namespace
  argocd_gateway_params    = "argocd-nlb-params"

  # TLS only applies to the Gateway we provision ourselves; a reused Gateway is
  # configured by whoever owns it.
  argocd_gateway_tls = var.argocd_gateway_create && var.argocd_gateway_tls_certificate_arn != ""

  argocd_gateway_service_annotations = merge(
    var.argocd_gateway_annotations,
    local.argocd_gateway_tls ? merge({
      "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"  = var.argocd_gateway_tls_certificate_arn
      "service.beta.kubernetes.io/aws-load-balancer-ssl-ports" = tostring(var.argocd_gateway_tls_port)
      }, var.argocd_gateway_tls_negotiation_policy == "" ? {} : {
      "service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy" = var.argocd_gateway_tls_negotiation_policy
    }) : {},
  )

  # Attaching to both listeners of our own Gateway needs no extra input: the
  # same config decides that the TLS listener exists at all.
  argocd_route_section_names = local.argocd_gateway_tls ? [
    var.argocd_gateway_section_name,
    var.argocd_gateway_https_section_name,
  ] : [var.argocd_gateway_section_name]

  argocd_url_scheme = local.argocd_gateway_tls || var.argocd_gateway_section_name == "https" ? "https" : "http"

  # Reaching the Argo CD UI depends on whether it is published through
  # kgateway; keeping both variants here keeps the `instructions` output a
  # plain heredoc instead of one carrying template directives.
  argocd_password_step = "Password run this command to get the initial password: 'kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d'"

  argocd_login_instructions = var.enable_argocd_route ? join("\n", [
    "1) Get the address of the Gateway serving Argo CD: 'kubectl get svc ${local.argocd_gateway_name} -n ${local.argocd_gateway_namespace} -o jsonpath=\"{.status.loadBalancer.ingress[0].hostname}\"'",
    var.argocd_hostname == "" ? "2) The route matches any Host, so open '${local.argocd_url_scheme}://<that address>' directly" : "2) Point '${var.argocd_hostname}' at that address (a DNS record, or an /etc/hosts entry), then open '${local.argocd_url_scheme}://${var.argocd_hostname}'",
    "3) Uses user 'admin'",
    "4) ${local.argocd_password_step}",
    ]) : join("\n", [
    "1) Argo CD is not published outside the cluster -- set 'enable_argocd_route = true' to expose it through kgateway. Meanwhile: 'kubectl port-forward svc/argocd-server -n ${var.argocd_namespace} 8080:80' and open 'http://localhost:8080'",
    "2) Uses user 'admin'",
    "3) ${local.argocd_password_step}",
  ])

  # My Public IP
  my_ip = "${chomp(data.http.my_ip.response_body)}/32"

  # Monitoring (11-monitoring.tf)
  grafana_gateway_name = "grafana-gateway"

  victoria_metrics_k8s_stack_values = {
    victoria-metrics-operator = {
      # The webhook's certificate is generated with genCA on every chart
      # render, which Argo CD would see as permanent drift.
      admissionWebhooks = { enabled = false }

      # The parent chart turns this on (the operator subchart defaults it off)
      # and it cannot work at this release name. The hook Job is called
      # <release>-victoria-metrics-operator-cleanup-hook -- 65 characters here
      # -- and Kubernetes copies that into the pod template's automatic
      # `job-name` label, where a value may not exceed 63 bytes. The API server
      # rejects the Job, Argo CD retries the PreDelete hook forever, and the
      # Application never finishes terminating:
      #
      #   error executing pre-delete hooks: Job.batch "...-cleanup-hook" is
      #   invalid: spec.template.labels: Invalid value: "...": must be no more
      #   than 63 bytes
      #
      # All the hook does is delete the VictoriaMetrics CRDs on uninstall. On
      # `terraform destroy` the cluster goes anyway, so nothing is lost; the
      # cost is that deleting only this Application on a live cluster leaves
      # the CRDs behind, which a re-apply reuses. That is the better failure:
      # the hook's actual job is to delete CRDs, and deleting a CRD deletes
      # every custom resource of that kind with it.
      #
      # The alternative is a shorter release name, which renames every object
      # the chart owns -- including the Grafana secret that outputs.tf and the
      # ignoreDifferences entry below both refer to by name.
      crds = {
        cleanup = { enabled = false }
      }

      # Prune the operator LAST, after everything else the chart owns.
      #
      # VMSingle and VMAgent carry apps.victoriametrics.com/finalizer, and only
      # the operator clears it. Argo CD's prune has no ordering of its own, so
      # it removed the operator's Deployment alongside the custom resources it
      # was supposed to finalize -- and the two CRs were left deleting forever,
      # with nothing left in the cluster that could ever release them:
      #
      #   Some content in the namespace has finalizers remaining:
      #   apps.victoriametrics.com/finalizer in 2 resource instances
      #
      # That is enough to wedge the whole teardown. A namespace cannot finish
      # Terminating while those CRs exist, the Grafana Service goes with it so
      # its NLB is never deleted, the still-mapped public addresses block the
      # internet gateway detach, and the subnets then fail with
      # DependencyViolation.
      #
      # PruneLast=true holds the operator back until every other resource is
      # pruned, which is exactly the window its finalizers need.
      annotations = {
        "argocd.argoproj.io/sync-options" = "PruneLast=true"
      }
    }

    vmsingle = {
      spec = {
        retentionPeriod = var.monitoring_retention
        storage = {
          storageClassName = "gp3"
          accessModes      = ["ReadWriteOnce"]
          resources        = { requests = { storage = var.monitoring_storage_size } }
        }
      }
    }

    # No notification receivers are configured yet, so an Alertmanager and a
    # rule evaluator would only use capacity. The recording/alerting rules are
    # still created and can be turned on later.
    alertmanager = { enabled = false }
    vmalert      = { enabled = false }

    # EKS runs the control plane outside the cluster: these endpoints do not
    # exist, and scraping them only produces permanently-down targets.
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeEtcd              = { enabled = false }

    # A DaemonSet pod has to fit on every node, including the system nodes that
    # are already at their max-pods limit; the priority lets it preempt.
    prometheus-node-exporter = {
      priorityClassName = "system-node-critical"
    }

    grafana = {
      # The RWO volume cannot be attached to the old and new pod at once.
      deploymentStrategy = { type = "Recreate" }
      persistence = {
        enabled          = true
        type             = "pvc"
        storageClassName = "gp3"
        size             = "5Gi"
      }
      "grafana.ini" = {
        server = {
          root_url = var.grafana_hostname == "" ? "%(protocol)s://%(domain)s:%(http_port)s/" : "http://${var.grafana_hostname}/"
        }
      }
      route = {
        main = {
          enabled   = var.enable_grafana_route
          hostnames = var.grafana_hostname == "" ? [] : [var.grafana_hostname]
          # group/kind spelled out: the API server defaults them, and leaving
          # them implicit makes Argo CD report the route as OutOfSync forever.
          parentRefs = [{
            group       = "gateway.networking.k8s.io"
            kind        = "Gateway"
            name        = local.grafana_gateway_name
            sectionName = "http"
          }]
        }
      }
    }
  }

  # KEDA -- see 12-keda.tf for why it is here at all.
  keda_values = {
    # The operator mints the serving certificates for the admission webhooks
    # and the metrics apiserver at runtime and patches the caBundle into the
    # cluster objects itself. The alternative is cert-manager, which this
    # cluster does not run. ignoreDifferences in 12-keda.tf is the other half.
    certificates = { autoGenerated = true }

    metricsServer = {
      # The aggregated external.metrics.k8s.io apiserver is in the HPA's path:
      # while it is unreachable every ScaledObject-backed HPA reports
      # "unable to fetch metrics" and holds its replica count. With Karpenter
      # on spot, a single replica means that happens on every reclaim.
      replicaCount = 2
    }

    podDisruptionBudget = {
      # Node consolidation drains one node at a time; this stops it taking
      # both apiserver replicas at once.
      metricServer = { minAvailable = 1 }
    }
  }
}
