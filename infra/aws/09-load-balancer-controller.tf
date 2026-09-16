################################################################################
# AWS Load Balancer Controller
#
# EKS Auto Mode used to ship this controller as part of the cluster; with Auto
# Mode off (02-eks.tf) nothing else installs it, and without it every
# `service.beta.kubernetes.io/aws-load-balancer-*` annotation in the repo is
# inert -- the kgateway Gateways (counter-api's and, when
# argocd_gateway_create is true, Argo CD's) would sit forever with no NLB and
# no external address. It is a hard dependency of the Gateway API setup, not an
# optional extra.
################################################################################

resource "aws_iam_policy" "aws_load_balancer_controller" {
  name        = "${local.name}-aws-load-balancer-controller"
  description = "Permissions for the AWS Load Balancer Controller on ${local.name_cluster}"

  # Verbatim from the controller's own release (see the file's header comment
  # for the version it was taken from). Round-tripping it through
  # jsondecode/jsonencode strips the formatting whitespace, which matters: an
  # IAM policy document is capped at 6144 characters and this one is close.
  policy = jsonencode(jsondecode(file("${path.module}/policies/aws-load-balancer-controller.json")))

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Project     = "Chamo"
  }
}

data "aws_iam_policy_document" "aws_load_balancer_controller_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "aws_load_balancer_controller" {
  name               = "${local.name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.aws_load_balancer_controller_assume.json

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Project     = "Chamo"
  }
}

resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  role       = aws_iam_role.aws_load_balancer_controller.name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}

# Pod Identity rather than IRSA, to match how module.karpenter gets its
# credentials -- one mechanism in the cluster, and no OIDC trust policy to keep
# in sync. The eks-pod-identity-agent addon in 02-eks.tf is what makes it work.
resource "aws_eks_pod_identity_association" "aws_load_balancer_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = var.load_balancer_controller_namespace
  service_account = var.load_balancer_controller_service_account
  role_arn        = aws_iam_role.aws_load_balancer_controller.arn
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.load_balancer_controller_chart_version

  namespace = var.load_balancer_controller_namespace

  wait    = true
  timeout = 600

  values = [yamlencode({
    clusterName = module.eks.cluster_name
    region      = var.region
    vpcId       = module.vpc.vpc_id

    serviceAccount = {
      create = true
      name   = var.load_balancer_controller_service_account
    }
  })]

  depends_on = [
    aws_eks_pod_identity_association.aws_load_balancer_controller,
    aws_iam_role_policy_attachment.aws_load_balancer_controller,
  ]
}
