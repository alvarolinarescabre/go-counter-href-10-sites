# Optional kgateway-based ingress for the Argo CD UI.
#
# Without this, Argo CD is only reachable through `kubectl port-forward`: the
# argo-cd Helm chart creates no Ingress/Gateway of its own, and nothing else in
# this config exposed it. Set var.enable_argocd_route = true to publish it
# through the same Gateway API implementation the application uses.
#
# The backend is argocd-server:80 over plain HTTP because 03-argocd.tf sets
# `server.insecure = true` — TLS, if any, terminates at the Gateway/NLB.

# Dedicated NLB configuration, only when we provision our own Gateway. Mirrors
# deploy/argocd/kgateway/parameters.yaml, which does the same for the Gateway
# the counter-api chart creates.
resource "kubectl_manifest" "argocd_gateway_parameters" {
  count = var.enable_argocd_route && var.argocd_gateway_create ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.kgateway.dev/v1alpha1"
    kind       = "GatewayParameters"
    metadata = {
      name      = local.argocd_gateway_params
      namespace = var.argocd_namespace
    }
    spec = {
      kube = {
        service = {
          extraAnnotations = local.argocd_gateway_service_annotations
        }
      }
    }
  })

  depends_on = [helm_release.argocd, kubectl_manifest.kgateway_helm]
}

resource "kubectl_manifest" "argocd_gateway" {
  count = var.enable_argocd_route && var.argocd_gateway_create ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = local.argocd_gateway_name
      namespace = local.argocd_gateway_namespace
    }
    spec = {
      gatewayClassName = var.argocd_gateway_class_name
      infrastructure = {
        # parametersRef is a *local* reference (group/kind/name only): the
        # GatewayParameters must live in the Gateway's own namespace.
        parametersRef = {
          group = "gateway.kgateway.dev"
          kind  = "GatewayParameters"
          name  = local.argocd_gateway_params
        }
      }
      # The TLS listener's protocol is HTTP, not HTTPS, and carries no `tls`
      # block on purpose: the NLB terminates TLS with the ACM certificate and
      # forwards the decrypted stream here, so the Gateway never sees a
      # handshake and no certificate has to exist inside the cluster.
      listeners = concat([{
        name     = var.argocd_gateway_section_name
        protocol = "HTTP"
        port     = 80
        allowedRoutes = {
          namespaces = { from = "Same" }
        }
        }], local.argocd_gateway_tls ? [{
        name     = var.argocd_gateway_https_section_name
        protocol = "HTTP"
        port     = var.argocd_gateway_tls_port
        allowedRoutes = {
          namespaces = { from = "Same" }
        }
      }] : [])
    }
  })

  depends_on = [kubectl_manifest.argocd_gateway_parameters]
}

resource "kubectl_manifest" "argocd_httproute" {
  count = var.enable_argocd_route ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "argocd-server"
      namespace = var.argocd_namespace
    }
    spec = {
      parentRefs = [
        for section in local.argocd_route_section_names : {
          name        = local.argocd_gateway_name
          namespace   = local.argocd_gateway_namespace
          sectionName = section
        }
      ]
      # An empty argocd_hostname means "no hostnames", i.e. match any Host
      # header, so the UI answers directly on the Gateway's NLB DNS name and no
      # domain is needed at all. On a shared Gateway that also makes Argo CD the
      # catch-all for every Host that no other route claims -- see the variable.
      hostnames = var.argocd_hostname == "" ? [] : [var.argocd_hostname]
      rules = [{
        matches = [{
          path = {
            type  = "PathPrefix"
            value = "/"
          }
        }]
        backendRefs = [{
          name = "argocd-server"
          port = 80
        }]
      }]
    }
  })

  # When reusing the counter-api Gateway (argocd_gateway_create = false), that
  # Gateway is created by Argo CD syncing the chart, not by Terraform, so it
  # may not exist yet when this route is applied. That is not an apply error:
  # the HTTPRoute simply stays Accepted=False until its parent shows up and
  # kgateway reconciles it. argocd_application is only a best-effort ordering
  # hint for that case.
  depends_on = [
    kubectl_manifest.argocd_gateway,
    kubectl_manifest.kgateway_helm,
    kubectl_manifest.argocd_application,
    helm_release.argocd,
  ]
}
