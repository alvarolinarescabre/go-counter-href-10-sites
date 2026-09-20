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

    # Off, deliberately. This webhook exists to make the controller the default
    # for every new Service of type LoadBalancer by stamping a loadBalancerClass
    # on it -- needed only when a Service does NOT say who should handle it.
    #
    # Every NLB Service here is created by kgateway from GatewayParameters that
    # already carry `aws-load-balancer-type: external` (this repo's
    # deploy/argocd/kgateway/parameters.yaml, the counter-api chart's values,
    # and var.argocd_gateway_annotations), so the mutation is redundant.
    #
    # What it is not is harmless: the chart registers it with
    # failurePolicy: Fail and no selector, so it intercepts EVERY Service
    # creation in the cluster. Any moment the controller has no ready endpoints
    # -- a rollout, a node replacement, a Karpenter consolidation -- no Service
    # can be created anywhere. That is what breaks the Karpenter install in
    # 08-karpenter.tf on a cold cluster.
    enableServiceMutatorWebhook = false
  })]

  # module.eks, not just the cluster: this chart's pods need somewhere to RUN,
  # and the managed node group is the only compute that is not itself managed
  # from inside the cluster. Referencing module.eks.cluster_name (as the values
  # above do) builds an edge to the cluster and to nothing else, so on destroy
  # Terraform is free to delete the node group *in parallel* with this release.
  # That is what deadlocked the teardown on 2026-09-20: the system nodes went
  # away mid-drain, every controller went Pending, and the NodeClaim finalizers
  # that only Karpenter can clear were left with no Karpenter to clear them.
  # A depends_on over the whole module covers its node group too.
  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.aws_load_balancer_controller,
    aws_iam_role_policy_attachment.aws_load_balancer_controller,
  ]
}

################################################################################
# Teardown barrier
#
# Every NLB in this stack is created by THIS controller, in response to a
# Service of type LoadBalancer that kgateway provisions for a Gateway. Terraform
# does not own those NLBs and cannot delete them; all it can do is delete the
# Gateway (or the Argo CD Application that owns it) and let the chain run:
#
#   Gateway/Application deleted -> kgateway deletes the Service
#     -> this controller sees the Service's service.k8s.aws/resources finalizer
#     -> it deletes the NLB -> only then does the Service actually go away
#
# All of that is asynchronous. A `kubectl_manifest` delete returns as soon as
# the CR is gone, so without this barrier Terraform tears down the controller
# (and seconds later the cluster) while the NLBs are still being deleted. The
# controller dies mid-flight, the NLB is orphaned, its ENIs keep holding the
# private subnets, and the VPC destroy fails with DependencyViolation.
#
# On create this is a no-op (no create_duration). On destroy it holds the
# controller -- and therefore the cluster -- alive for var.load_balancer_teardown_wait
# after the last Gateway is deleted.
################################################################################

resource "time_sleep" "load_balancer_teardown" {
  depends_on = [helm_release.aws_load_balancer_controller]

  destroy_duration = var.load_balancer_teardown_wait
}
