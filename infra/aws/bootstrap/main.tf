################################################################################
# CI credentials bootstrap
#
# The two IAM users the GitHub Actions workflow authenticates as, and the
# policies they carry. Separate Terraform root from ../ on purpose: these users
# ARE the credentials the main stack runs with, so managing them from inside it
# would mean an apply can revoke the permissions of the very run performing it,
# and the first apply could never happen at all -- the users have to exist
# before anything can authenticate.
#
# Run this once, by a human with administrator credentials:
#
#     cd infra/aws/bootstrap
#     terraform init && terraform apply
#
# See README.md here for adopting the users if they already exist.
################################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name = "${var.project_name}-${var.environment}"

  # Everything the main stack names after itself -- the roles, policies and
  # instance profiles in 08/09/10-*.tf and the ones the EKS module derives from
  # the cluster name. The apply user's IAM permissions are scoped to this
  # prefix so it cannot touch IAM outside the project.
  resource_prefix = "${local.name}-"

  state_bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket}"

  ci_users = {
    plan  = var.plan_user_name
    apply = var.apply_user_name
  }

  iam_arn_base = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}"
}

resource "aws_iam_user" "ci" {
  for_each = local.ci_users

  name = each.value

  tags = {
    Purpose = "GitHub Actions Terraform ${each.key}"
  }
}

################################################################################
# Shared: state access and the lookups every run needs
################################################################################

data "aws_iam_policy_document" "terraform_shared" {
  # `use_lockfile = true` in ../providers.tf means even a read-only plan writes
  # and deletes `terraform.tfstate.tflock` in the bucket. A genuinely read-only
  # S3 grant here would make every plan fail to acquire its lock.
  statement {
    sid    = "TerraformState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketVersioning",
    ]
    resources = [local.state_bucket_arn, "${local.state_bucket_arn}/*"]
  }

  # 10-cluster-access.tf resolves the AWSReservedSSO_* roles that IAM Identity
  # Center has provisioned in this account, to build the EKS access entries from
  # them. That lookup happens at PLAN time, so both users need it -- without it
  # the read-only plan job fails just as hard as the apply job.
  statement {
    sid       = "IdentityCenterRoleDiscovery"
    effect    = "Allow"
    actions   = ["iam:ListRoles", "iam:GetRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "terraform_shared" {
  name        = "${local.name}-terraform-shared"
  description = "Terraform state access and the IAM lookups both CI users need at plan time"
  policy      = data.aws_iam_policy_document.terraform_shared.json
}

resource "aws_iam_user_policy_attachment" "terraform_shared" {
  for_each = aws_iam_user.ci

  user       = each.value.name
  policy_arn = aws_iam_policy.terraform_shared.arn
}

################################################################################
# Plan user: read-only
################################################################################

# AWS's own ReadOnlyAccess rather than a hand-written Describe*/List*/Get* list.
# A plan touches every service in the stack and a missing read action does not
# degrade gracefully -- it fails the run. AWS extends this policy as services
# grow; a hand-rolled equivalent silently rots instead.
#
# It also already covers iam:ListRoles, but the shared policy above grants that
# explicitly anyway: the apply user's Deny statements below carve into IAM, and
# a grant this specific should not depend on an AWS-managed policy's contents
# staying the way they are today.
resource "aws_iam_user_policy_attachment" "plan_read_only" {
  user       = aws_iam_user.ci["plan"].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

################################################################################
# Apply user: read/write
################################################################################

data "aws_iam_policy_document" "terraform_apply" {
  # Service-level grants. Deliberately broad: the stack creates a VPC, an EKS
  # cluster and its addons, Karpenter's SQS queue and EventBridge rules, an ECR
  # repository, NLBs and the KMS key the EKS module derives -- and Terraform
  # needs the delete side of every one of them for `destroy` to work at all.
  # Scoping these down to resource ARNs is the next tightening step, and it
  # needs the ARNs of a cluster that already exists.
  statement {
    sid    = "InfrastructureServices"
    effect = "Allow"
    actions = [
      "ec2:*",
      "eks:*",
      "elasticloadbalancing:*",
      "autoscaling:*",
      "ecr:*",
      "sqs:*",
      "events:*",
      "kms:*",
      "logs:*",
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = ["*"]
  }

  # IAM, scoped by name to what the main stack creates: the cluster, node group,
  # Karpenter and load-balancer-controller roles, the break-glass role, and
  # their policies and instance profiles. All of them are named
  # `<project>-<env>-*`, or after the cluster, which carries the same prefix.
  statement {
    sid    = "ProjectIamResources"
    effect = "Allow"
    actions = [
      "iam:*Role*",
      "iam:*Policy*",
      "iam:*InstanceProfile*",
      "iam:PassRole",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = [
      "${local.iam_arn_base}:role/${local.resource_prefix}*",
      "${local.iam_arn_base}:policy/${local.resource_prefix}*",
      "${local.iam_arn_base}:instance-profile/${local.resource_prefix}*",
    ]
  }

  # Karpenter's spot instances need AWSServiceRoleForEC2Spot, and the EKS and
  # ELB integrations need theirs. These are AWS-owned roles under
  # /aws-service-role/, so they cannot match the project prefix above -- the
  # condition is what keeps this from being a general role-creation grant.
  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "spot.amazonaws.com",
        "spotfleet.amazonaws.com",
        "eks.amazonaws.com",
        "eks-nodegroup.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
      ]
    }
  }

  # The EKS module creates the cluster's OIDC provider, which is an
  # account-level IAM resource with a URL-derived name that no prefix matches.
  statement {
    sid       = "OidcProvider"
    effect    = "Allow"
    actions   = ["iam:*OpenIDConnectProvider*"]
    resources = ["*"]
  }

  # Guard rail. Without it, `iam:*Role*` and `iam:*Policy*` above could be aimed
  # at the users and policies that define what this user may do -- it could
  # widen its own permissions, and the scoping would be decorative. An explicit
  # Deny beats every Allow, including one added here by mistake later.
  statement {
    sid    = "DenySelfEscalation"
    effect = "Deny"
    actions = [
      "iam:*User*",
      "iam:*AccessKey*",
      "iam:*LoginProfile*",
      "iam:*Group*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyBootstrapPolicyChanges"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
    ]
    resources = [
      "${local.iam_arn_base}:policy/${local.name}-terraform-shared",
      "${local.iam_arn_base}:policy/${local.name}-terraform-apply",
    ]
  }
}

resource "aws_iam_policy" "terraform_apply" {
  name        = "${local.name}-terraform-apply"
  description = "Create/update/delete for everything the ${local.name} EKS stack provisions"
  policy      = data.aws_iam_policy_document.terraform_apply.json
}

resource "aws_iam_user_policy_attachment" "terraform_apply" {
  user       = aws_iam_user.ci["apply"].name
  policy_arn = aws_iam_policy.terraform_apply.arn
}

# The apply user needs everything the plan user reads too: an apply begins by
# refreshing state, which is the same set of read calls.
resource "aws_iam_user_policy_attachment" "apply_read_only" {
  user       = aws_iam_user.ci["apply"].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

################################################################################
# Access keys (opt-in -- see var.create_access_keys)
################################################################################

resource "aws_iam_access_key" "ci" {
  for_each = var.create_access_keys ? aws_iam_user.ci : {}

  user = each.value.name
}
