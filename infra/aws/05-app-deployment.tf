resource "kubectl_manifest" "argocd_app_project" {
  yaml_body = file("${path.root}/../../deploy/argocd/app-project.yaml")

  depends_on = [kubectl_manifest.kgateway_helm]
}

# The manifest carries resources-finalizer.argocd.argoproj.io, so deleting this
# cascades to everything the chart deployed -- including the Gateway whose
# Service owns the application's NLB. time_sleep.load_balancer_teardown keeps
# the load balancer controller alive while that cascade runs.
resource "kubectl_manifest" "argocd_application" {
  yaml_body = file("${path.root}/../../deploy/argocd/application.yaml")

  # karpenter_node_pool is in here for the ordering it gives on BOTH ends.
  #
  # Creating: the NodePool exists before the application is handed to Argo CD,
  # so its pods have somewhere to be scheduled instead of sitting Pending.
  #
  # Destroying: the application -- and the counter-api PodDisruptionBudget
  # (maxUnavailable 25%) and the gateway proxy's (minAvailable 1) -- are gone
  # before Karpenter starts draining. A PDB cannot block the eviction of a pod
  # that no longer exists; with the workloads still running, the NodePool delete
  # blocks behind them.
  #
  # wait_for_keda_crds: the chart renders its ScaledObject only if
  # keda.sh/v1alpha1 is a registered API (see scaledobject.yaml), and with
  # autoscaling.keda.enabled the plain HPA is not rendered at all. Syncing
  # before KEDA is up would leave the Deployment with no autoscaler until Argo
  # CD's next reconcile.
  depends_on = [
    kubectl_manifest.argocd_app_project,
    kubectl_manifest.karpenter_node_pool,
    time_sleep.load_balancer_teardown,
    time_sleep.wait_for_keda_crds,
  ]
}