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
  # Nothing in Terraform owns the counter-api NLB: the chart's Gateway makes
  # kgateway provision a Service, and the load balancer controller creates the
  # NLB from that. Deleting this Application used to return the moment the API
  # server accepted the DELETE, while Argo CD was still cascading -- leaving
  # only time_sleep.load_balancer_teardown's timer between the cascade and the
  # controller being removed. A slow NLB delete outran it and orphaned the
  # load balancer, its ENIs then failing the VPC destroy.
  #
  # The Application carries resources-finalizer.argocd.argoproj.io, which Argo
  # CD clears only once it has pruned every resource the chart deployed. `wait`
  # blocks on exactly that finalizer, so this delete now returns when the NLB
  # is really gone. The timer stays as a backstop, not as the mechanism.
  #
  # Escape hatch if the cascade ever wedges (a stuck PVC finalizer, say) and
  # the destroy hangs here:
  #   kubectl patch application counter-api -n argocd --type=merge \
  #     -p '{"metadata":{"finalizers":null}}'
  # That orphans whatever had not been pruned yet -- check with the post-destroy
  # verification in the README before walking away.
  wait           = true
  delete_cascade = "Foreground"

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