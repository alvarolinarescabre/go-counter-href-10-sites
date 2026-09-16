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

  depends_on = [module.eks]
}

resource "kubectl_manifest" "victoria_metrics_k8s_stack" {
  count = var.enable_monitoring ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "victoria-metrics-k8s-stack"
      namespace = var.argocd_namespace
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

  depends_on = [
    kubectl_manifest.monitoring_namespace,
    kubectl_manifest.gp3_storage_class,
    time_sleep.wait_for_argocd_crds,
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

  depends_on = [kubectl_manifest.monitoring_namespace, kubectl_manifest.kgateway_helm]
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

  depends_on = [
    kubectl_manifest.grafana_gateway_parameters,
    helm_release.aws_load_balancer_controller,
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
