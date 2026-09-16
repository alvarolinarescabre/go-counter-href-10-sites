################################################################################
# Human access to the cluster
#
# Not IRSA: IRSA (IAM Roles for Service Accounts) binds an IAM role to a
# Kubernetes *service account* through the cluster's OIDC provider, which is how
# in-cluster workloads get AWS credentials. A person running kubectl has no
# service account to bind. The human path is an IAM role that maps to an EKS
# *access entry*, and this file wires up two of them:
#
#   1. IAM Identity Center (below) -- the normal way in. People sign in to the
#      access portal, pick a permission set, and the credentials they get are
#      already an IAM role: AWSReservedSSO_<permission set>_<hash>. Nothing to
#      assume by hand, nothing long-lived, group membership in the identity
#      store is the only thing that grants or revokes access.
#   2. A break-glass role (further down) -- an ordinary assumable IAM role, for
#      when Identity Center itself is what is broken.
#
# Both end up as EKS access entries, built in locals.tf
# (local.sso_access_entries and local.break_glass_access_entries) and passed to
# the EKS module in 02-eks.tf -- the module owns that argument.
################################################################################

################################################################################
# IAM Identity Center
################################################################################

# Terraform does not create the permission sets -- they are managed wherever
# Identity Center is administered, which is usually not this account. What it
# does is find the role each one has *already been provisioned as* here, because
# that role ARN is what an access entry has to name and the `_<hash>` suffix in
# it is assigned by Identity Center, not by us.
#
# So the ordering is: assign the permission set to this account first, then
# apply this. A permission set that has never been assigned to this account has
# no role here and the precondition below says so.
data "aws_iam_roles" "sso_permission_sets" {
  for_each = var.sso_access_permission_sets

  name_regex  = "AWSReservedSSO_${each.key}_.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

# Without this, a permission set that is not provisioned in the account fails
# much later and much less clearly -- `one()` returns null and the ARN
# expression dies on a null argument, naming neither the permission set nor
# what to do about it.
resource "terraform_data" "sso_permission_set_provisioned" {
  for_each = var.sso_access_permission_sets

  input = each.key

  lifecycle {
    precondition {
      condition     = length(data.aws_iam_roles.sso_permission_sets[each.key].arns) == 1
      error_message = <<-EOT
        Expected exactly one IAM role for Identity Center permission set "${each.key}" in this account, found ${length(data.aws_iam_roles.sso_permission_sets[each.key].arns)}.

        0 means the permission set is not assigned to this account (assign it in Identity Center, then re-apply), or that its name is misspelled in var.sso_access_permission_sets -- the key must match the permission set name exactly, case included.

        More than 1 means the name is a prefix of another permission set's (e.g. "EKSAdmin" also matching "EKSAdminReadOnly"); rename one of them.
      EOT
    }
  }
}

################################################################################
# Break-glass role
#
# A plain assumable IAM role with cluster-admin, deliberately independent of
# Identity Center: if the identity store, the access portal or the permission
# set provisioning is the thing that is broken, every SSO route into the cluster
# is broken with it, and this is what is left.
#
# It is not a second everyday door. Keep the assume policy attached to nobody by
# default, hand it out during an incident, and treat every use as something to
# review afterwards -- CloudTrail records `AssumeRole` on it with the human's
# own identity as the caller.
################################################################################

data "aws_iam_policy_document" "break_glass_assume" {
  count = var.break_glass_role_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "AWS"
      identifiers = local.break_glass_trusted_principals
    }

    # Naming the account root as a principal is not "anyone in the account": it
    # delegates the decision to the account's own IAM, so a principal gets in
    # only if an identity policy *also* allows sts:AssumeRole on this role.
    # aws_iam_policy.break_glass below is that policy, attached to nobody until
    # someone needs it.
    dynamic "condition" {
      for_each = var.break_glass_require_mfa ? [1] : []

      content {
        test     = "Bool"
        variable = "aws:MultiFactorAuthPresent"
        values   = ["true"]
      }
    }
  }
}

resource "aws_iam_role" "break_glass" {
  count = var.break_glass_role_enabled ? 1 : 0

  name        = "${local.name}-eks-break-glass"
  description = "Emergency cluster-admin access to ${local.name_cluster}, for when IAM Identity Center is unavailable"

  assume_role_policy   = data.aws_iam_policy_document.break_glass_assume[0].json
  max_session_duration = var.break_glass_max_session_duration

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Project     = "Chamo"
    Cluster     = local.name_cluster
    Access      = "break-glass"
  }
}

resource "aws_iam_policy" "break_glass" {
  count = var.break_glass_role_enabled ? 1 : 0

  name        = "${local.name}-eks-break-glass-assume"
  description = "Allows assuming ${aws_iam_role.break_glass[0].name}. Attach only for the duration of an incident."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.break_glass[0].arn
      },
      {
        # Without this the CLI cannot resolve the cluster endpoint to write a
        # kubeconfig at all, so the break-glass path would fail before any of
        # the Kubernetes-side permissions came into play.
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = module.eks.cluster_arn
      },
    ]
  })

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Project     = "Chamo"
  }
}
