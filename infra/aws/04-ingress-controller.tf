resource "kubectl_manifest" "kgateway_crds" {
  for_each  = data.kubectl_file_documents.kgateway_crds.manifests
  yaml_body = each.value

  depends_on = [module.eks]
}


# helm_release.argocd finishing just means Helm reports the release ready
# (its pods are up); it does NOT guarantee the argoproj.io/v1alpha1 CRDs it
# installs are registered/discoverable via the Kubernetes API server yet.
# kubectl_manifest.kgateway_helm_cdrs below applies an Application CR of
# that exact CRD, but has no attribute-based reference to helm_release.argocd
# for Terraform to infer an ordering from — without this, both resources can
# run in parallel and the Application CR creation fails with "isn't valid
# for cluster" because the CRD isn't there yet. This sleep is the standard
# workaround for this Helm-CRD-then-CR race.
resource "time_sleep" "wait_for_argocd_crds" {
  depends_on      = [helm_release.argocd]
  create_duration = "30s"
}

resource "kubectl_manifest" "kgateway_helm_cdrs" {
  yaml_body = file("${path.root}/../../deploy/argocd/kgateway/crds-helm.yaml")

  depends_on = [kubectl_manifest.kgateway_crds, time_sleep.wait_for_argocd_crds]
}

resource "kubectl_manifest" "kgateway_helm" {
  yaml_body = file("${path.root}/../../deploy/argocd/kgateway/helm.yaml")

  depends_on = [kubectl_manifest.kgateway_helm_cdrs]
}

# Exactly the race the comment above describes, one level down.
#
# The two resources above only create Argo CD `Application` objects. Terraform
# returns the moment the CR exists -- it has NOT installed kgateway. Argo CD
# still has to notice the Application, pull the chart from cr.kgateway.dev and
# sync it, and only then does the API server register
# gateway.kgateway.dev/v1alpha1. Anything applying a GatewayParameters before
# that fails with "isn't valid for cluster, check the APIVersion and Kind
# fields are valid".
#
# Unlike the Argo CD sleep above this covers a chart pull over the network for
# TWO applications (kgateway-crds, then the controller), so it is longer and
# configurable -- see var.kgateway_sync_wait.
resource "time_sleep" "wait_for_kgateway_crds" {
  depends_on      = [kubectl_manifest.kgateway_helm]
  create_duration = var.kgateway_sync_wait
}