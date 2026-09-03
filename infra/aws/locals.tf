locals {

  # General Information
  name = "${var.project_name}-${var.environment}"

  # EKS Cluster Information
  name_cluster     = "${local.name}-cluster"
  cluster_version  = var.cluster_version
  ami_type         = "AL2_x86_64"
  node_groups_name = "${local.name}-ng"

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
}
