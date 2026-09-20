################################################################################
# Monitoring: VictoriaMetrics + Grafana
#
# victoria-metrics-k8s-stack is installed as an Argo CD Application (same as
# kgateway), not a helm_release: Argo CD keeps it in sync and Terraform only
# owns the pieces the chart cannot provide itself -- persistent storage, the
# namespace, and the dedicated Gateway/NLB Grafana is published through.
#
#   vmagent  --scrapes-->  kubelet/cAdvisor, node-exporter, kube-state-metrics,
#                          CoreDNS, API server, counter-api (VMServiceScrape)
#   vmagent  --remote write-->  VMSingle (EBS gp3 volume)
#   Grafana  --queries-->  VMSingle
################################################################################

# ------------------------------------------------------------------ Storage
#
# With EKS Auto Mode off (02-eks.tf) nothing provisions EBS volumes: the only
# StorageClass is the legacy in-tree gp2 one, which no longer works on current
# Kubernetes. VMSingle and Grafana both need a PersistentVolume, so the EBS CSI
# driver is installed as an addon (see 02-eks.tf) with this role via Pod
# Identity, the same mechanism Karpenter and the load balancer controller use.

data "aws_iam_policy_document" "ebs_csi_driver_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_driver" {
  name               = "${local.name}-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_driver_assume.json

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Project     = "Chamo"
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Default StorageClass, so charts that leave storageClassName unset get an
# encrypted gp3 volume. WaitForFirstConsumer creates the volume in the AZ the
# pod is actually scheduled to.
resource "kubectl_manifest" "gp3_storage_class" {
  yaml_body = yamlencode({
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = "gp3"
      annotations = {
        "storageclass.kubernetes.io/is-default-class" = "true"
      }
    }
    provisioner          = "ebs.csi.aws.com"
    volumeBindingMode    = "WaitForFirstConsumer"
    allowVolumeExpansion = true
    reclaimPolicy        = "Delete"
    parameters = {
      type      = "gp3"
      encrypted = "true"
    }
  })

  depends_on = [module.eks]
}

# ------------------------------------------------------------------ Stack

resource "kubectl_manifest" "monitoring_namespace" {
  count = var.enable_monitoring ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = var.monitoring_namespace
    }
  })

  # Deleting the namespace blocks on the finalizers of everything still in it --
  # Grafana's LoadBalancer Service among them. The barrier is what keeps the
  # load balancer controller alive to clear those, instead of leaving the
  # namespace stuck Terminating and the NLB orphaned.
  depends_on = [module.eks, time_sleep.load_balancer_teardown]
}

resource "kubectl_manifest" "victoria_metrics_k8s_stack" {
  count = var.enable_monitoring ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "victoria-metrics-k8s-stack"
      namespace = var.argocd_namespace
      # Deleting an Application without this removes only the Application CR.
      # The monitoring namespace, the VMSingle and Grafana PVCs and the gp3 EBS
      # volumes behind them all survive `terraform destroy` -- the cluster goes
      # away and the volumes are billed forever. With it, the delete cascades
      # and the Application is not removed until its resources are gone.
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.monitoring_namespace
      }
      source = {
        repoURL        = "https://victoriametrics.github.io/helm-charts/"
        chart          = "victoria-metrics-k8s-stack"
        targetRevision = var.victoria_metrics_k8s_stack_chart_version
        helm = {
          valuesObject = local.victoria_metrics_k8s_stack_values
        }
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          # The operator CRDs exceed the 262 KiB last-applied-configuration
          # annotation limit of client-side apply.
          "ServerSideApply=true",
          # The Grafana chart generates a random admin password on every
          # render. Without this Argo CD would rewrite the Secret on each sync,
          # and the password stored in Grafana's database (set on first start)
          # would no longer match it.
          "RespectIgnoreDifferences=true",
        ]
      }
      ignoreDifferences = [{
        kind         = "Secret"
        name         = "victoria-metrics-k8s-stack-grafana"
        jsonPointers = ["/data/admin-password"]
      }]
    }
  })

  # The teardown barrier is in here too: the cascade above has to delete
  # Grafana's PVCs, and the EBS CSI driver behind them only works while the
  # cluster is still up.
  # karpenter_node_pool for the same reason as in 05-app-deployment.tf: these
  # pods (VMSingle, Grafana, node-exporter, kube-state-metrics) sit on
  # Karpenter-provisioned nodes, and they have to be gone before the NodePool is
  # drained rather than during it.
  depends_on = [
    kubectl_manifest.monitoring_namespace,
    kubectl_manifest.gp3_storage_class,
    kubectl_manifest.karpenter_node_pool,
    time_sleep.wait_for_argocd_crds,
    time_sleep.load_balancer_teardown,
  ]
}

# ------------------------------------------------------------------ Grafana ingress
#
# A dedicated Gateway (and therefore NLB) in the monitoring namespace, mirroring
# the Argo CD one in 06-argocd-ingress.tf. The HTTPRoute itself comes from the
# Grafana chart (grafana.route in the values above). Plain HTTP only, like Argo
# CD: there is no ACM certificate in this setup.

resource "kubectl_manifest" "grafana_gateway_parameters" {
  count = var.enable_monitoring && var.enable_grafana_route ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.kgateway.dev/v1alpha1"
    kind       = "GatewayParameters"
    metadata = {
      name      = "grafana-nlb-params"
      namespace = var.monitoring_namespace
    }
    spec = {
      kube = {
        service = {
          extraAnnotations = var.argocd_gateway_annotations
        }
      }
    }
  })

  depends_on = [kubectl_manifest.monitoring_namespace, time_sleep.wait_for_kgateway_crds]
}

resource "kubectl_manifest" "grafana_gateway" {
  count = var.enable_monitoring && var.enable_grafana_route ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = local.grafana_gateway_name
      namespace = var.monitoring_namespace
    }
    spec = {
      gatewayClassName = var.argocd_gateway_class_name
      infrastructure = {
        parametersRef = {
          group = "gateway.kgateway.dev"
          kind  = "GatewayParameters"
          name  = "grafana-nlb-params"
        }
      }
      listeners = [{
        name     = "http"
        protocol = "HTTP"
        port     = 80
        allowedRoutes = {
          namespaces = { from = "Same" }
        }
      }]
    }
  })

  # Same mechanism as the Karpenter NodePool in 08-karpenter.tf: kgateway
  # creates the LoadBalancer Service for this Gateway with an ownerReference
  # back to it, and that Service carries the load balancer controller's
  # service.k8s.aws/resources finalizer, which is only cleared once the NLB is
  # actually deleted. Blocking on the Gateway's Foreground cascade therefore
  # blocks until the NLB is gone, instead of returning while it is still being
  # deleted.
  #
  # time_sleep.load_balancer_teardown stays as a backstop. All three NLBs now
  # block their own delete -- the two Gateways Terraform owns through this
  # cascade, and counter-api's through the Argo CD finalizer on
  # kubectl_manifest.argocd_application -- so the timer is margin, not the
  # mechanism.
  wait           = true
  delete_cascade = "Foreground"

  # See time_sleep.load_balancer_teardown in 09-load-balancer-controller.tf:
  # the barrier replaces the direct dependency so that on destroy the
  # controller outlives this Gateway and can delete its NLB.
  depends_on = [
    kubectl_manifest.grafana_gateway_parameters,
    time_sleep.load_balancer_teardown,
  ]
}

# ------------------------------------------------------------------ Dashboards
#
# Picked up by the Grafana dashboard sidecar through the grafana_dashboard label.

resource "kubectl_manifest" "counter_api_dashboard" {
  count = var.enable_monitoring ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "counter-api-dashboard"
      namespace = var.monitoring_namespace
      labels = {
        grafana_dashboard = "1"
      }
    }
    data = {
      "counter-api.json" = file("${path.root}/../../deploy/monitoring/dashboards/counter-api.json")
    }
  })

  depends_on = [kubectl_manifest.monitoring_namespace]
}
