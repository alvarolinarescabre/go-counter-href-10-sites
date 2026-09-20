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

  depends_on = [helm_release.argocd, time_sleep.wait_for_kgateway_crds]
}

# The Gateway makes kgateway create a Service of type LoadBalancer carrying
# aws-load-balancer-* annotations; only the AWS Load Balancer Controller acts on
# those, so without it the Gateway would come up with no address at all.
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

  # Same mechanism as the Karpenter NodePool in 08-karpenter.tf: kgateway
  # creates the LoadBalancer Service for this Gateway with an ownerReference
  # back to it, and that Service carries the load balancer controller's
  # service.k8s.aws/resources finalizer, which is only cleared once the NLB is
  # actually deleted. Blocking on the Gateway's Foreground cascade therefore
  # blocks until the NLB is gone, instead of returning while it is still being
  # deleted.
  #
  # time_sleep.load_balancer_teardown stays as the backstop: it also covers the
  # counter-api NLB, whose Gateway Terraform does not own at all.
  wait           = true
  delete_cascade = "Foreground"

  # The barrier stands in for the controller here: same create order (the
  # controller first), but on destroy it keeps the controller alive long enough
  # to delete the NLB this Gateway's Service owns.
  depends_on = [
    kubectl_manifest.argocd_gateway_parameters,
    time_sleep.load_balancer_teardown,
  ]
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
