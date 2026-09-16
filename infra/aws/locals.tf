locals {

  # General Information
  name = "${var.project_name}-${var.environment}"

  # EKS Cluster Information
  name_cluster     = "${local.name}-cluster"
  cluster_version  = var.cluster_version
  ami_type         = "AL2023_x86_64_STANDARD"
  node_groups_name = "${local.name}-ng"

  # Karpenter discovers the subnets and the security group it should attach
  # provisioned nodes to by tag, not by ID -- these are the values its
  # EC2NodeClass selectors match on (08-karpenter.tf). The same value tags the
  # private subnets (01-vpc.tf) and the node security group (02-eks.tf).
  karpenter_discovery_tag = local.name_cluster
  karpenter_node_pool     = "default"
  karpenter_node_class    = "default"

  # Human cluster access (10-cluster-access.tf)
  #
  # Short keys map to the AWS-managed EKS access policies. These are AWS's own
  # ARNs, not IAM policies -- they live in the `eks::aws:cluster-access-policy/`
  # namespace and mean nothing except attached to an access entry.
  eks_access_policy_arns = {
    "cluster-admin" = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    "admin"         = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
    "admin-view"    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"
    "edit"          = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
    "view"          = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  }

  # Identity Center provisions its roles under a path
  # (/aws-reserved/sso.amazonaws.com/<region>/), and an EKS access entry must
  # name the role WITHOUT it -- a path-carrying ARN either fails to match the
  # principal at authentication time or is silently normalised, depending on the
  # API surface. Rebuilding the ARN from the bare role name avoids the question
  # entirely.
  sso_role_arns = {
    for k, d in data.aws_iam_roles.sso_permission_sets :
    k => "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${regex("[^/]+$", one(d.arns))}"
  }

  sso_access_entries = {
    for k, v in var.sso_access_permission_sets : "sso-${k}" => {
      principal_arn = local.sso_role_arns[k]

      policy_associations = {
        (v.access_policy) = {
          policy_arn = local.eks_access_policy_arns[v.access_policy]
          access_scope = v.namespaces == null ? { type = "cluster" } : {
            type       = "namespace"
            namespaces = v.namespaces
          }
        }
      }
    }
  }

  break_glass_trusted_principals = length(var.break_glass_trusted_principals) > 0 ? var.break_glass_trusted_principals : [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  ]

  break_glass_access_entries = var.break_glass_role_enabled ? {
    break-glass = {
      principal_arn = aws_iam_role.break_glass[0].arn

      policy_associations = {
        cluster-admin = {
          policy_arn   = local.eks_access_policy_arns["cluster-admin"]
          access_scope = { type = "cluster" }
        }
      }
    }
  } : {}

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
