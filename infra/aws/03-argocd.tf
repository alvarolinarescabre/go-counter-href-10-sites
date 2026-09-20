resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  namespace        = var.argocd_namespace
  create_namespace = true

  wait    = true
  timeout = 600

  values = [yamlencode({
    configs = {
      params = {
        "server.insecure" = true
      }
    }
    redis-ha       = { enabled = false }
    controller     = { replicas = 1 }
    server         = { replicas = 1 }
    repoServer     = { replicas = 1 }
    applicationSet = { replicas = 1 }
  })]

  # Wait for Load Balancer Controller to be ready
  # module.eks, not just the cluster: this chart's pods need somewhere to RUN,
  # and the managed node group is the only compute that is not itself managed
  # from inside the cluster. Referencing module.eks.cluster_name (as the values
  # above do) builds an edge to the cluster and to nothing else, so on destroy
  # Terraform is free to delete the node group *in parallel* with this release.
  # That is what deadlocked the teardown on 2026-09-20: the system nodes went
  # away mid-drain, every controller went Pending, and the NodeClaim finalizers
  # that only Karpenter can clear were left with no Karpenter to clear them.
  # A depends_on over the whole module covers its node group too.
  depends_on = [module.eks, helm_release.aws_load_balancer_controller]
}