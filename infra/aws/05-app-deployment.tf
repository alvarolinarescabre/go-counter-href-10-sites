resource "kubectl_manifest" "argocd_app_project" {
  yaml_body = file("${path.root}/../../deploy/argocd/app-project.yaml")

  depends_on = [kubectl_manifest.kgateway_helm]
}

resource "kubectl_manifest" "argocd_application" {
  yaml_body = file("${path.root}/../../deploy/argocd/application.yaml")

  depends_on = [kubectl_manifest.argocd_app_project]
}