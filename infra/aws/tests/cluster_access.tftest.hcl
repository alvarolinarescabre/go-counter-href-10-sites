################################################################################
# Shared mock setup -- repeated in every test file in this directory, because
# Terraform test files cannot share provider/mock blocks.
#
# Every provider is mocked, so the whole suite runs offline with no AWS
# credentials and touches nothing: `command = plan` only, and a mocked provider
# never calls an API even on apply. The defaults below exist because the AWS
# provider validates some of these values client-side, and a randomly generated
# mock string is not a valid ARN or a valid IAM policy document.
#
# Consequence worth knowing: anything whose value comes OUT of a provider is
# fake here. In particular `data.aws_iam_policy_document.*.json` is the stub
# below, not the real document -- assume-role policies are therefore not
# assertable in this root. The policies that ARE asserted (ECR lifecycle,
# break-glass) are built with jsonencode() in the config itself.
#
# terraform.tfvars IS loaded by `terraform test`, so a run block with no
# `variables` of its own is testing the configuration as actually deployed.
################################################################################

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-1a", "eu-west-1b", "eu-west-1c"] }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
      arn        = "arn:aws:iam::111122223333:user/terraform-test"
      id         = "111122223333"
      user_id    = "AIDAEXAMPLETESTUSER0"
    }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::111122223333:user/terraform-test" }
  }
  # The AWS provider rejects a non-JSON assume_role_policy client-side.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  # One role per permission set is what terraform_data.sso_permission_set_provisioned
  # requires; runs that care about the ARN override this per key.
  # On `command = apply` a mocked resource's computed attributes are random
  # strings, and the provider validates ARN-shaped ones client-side.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::111122223333:policy/mock" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::111122223333:instance-profile/mock" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:eu-west-1:111122223333:key/00000000-0000-0000-0000-000000000000" }
  }
  # The eks module reads the cluster's OIDC issuer and CA out of these nested
  # blocks; a mock with no elements makes it fail on an empty list.
  mock_resource "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:eu-west-1:111122223333:cluster/mock"
      certificate_authority = [{ data = "TU9DSw==" }]
      identity = [{
        oidc = [{ issuer = "https://oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE" }]
      }]
    }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-00000000000000000" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:eu-west-1:111122223333:mock" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:eu-west-1:111122223333:rule/mock" }
  }
  mock_resource "aws_ecr_repository" {
    defaults = { arn = "arn:aws:ecr:eu-west-1:111122223333:repository/mock" }
  }
  mock_resource "aws_eks_access_entry" {
    defaults = { access_entry_arn = "arn:aws:eks:eu-west-1:111122223333:access-entry/mock" }
  }

  mock_data "aws_eks_addon_version" {
    defaults = { version = "v1.0.0-eksbuild.1" }
  }
  mock_data "aws_iam_roles" {
    defaults = {
      arns = ["arn:aws:iam::111122223333:role/aws-reserved/sso.amazonaws.com/eu-west-1/AWSReservedSSO_Mock_0000000000000000"]
    }
  }
}

mock_provider "aws" { alias = "virginia" }
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "time" {}

mock_provider "http" {
  mock_data "http" {
    defaults = { response_body = "203.0.113.10\n" }
  }
}

mock_provider "kubectl" {
  mock_data "kubectl_file_documents" {
    defaults = { manifests = {} }
  }
}

# The eks module reads the OIDC issuer's certificate chain to build the IAM
# OIDC provider; unmocked, that is a real network call.
mock_provider "tls" {
  mock_data "tls_certificate" {
    defaults = {
      certificates = [{ sha1_fingerprint = "9e99a48a9960b14926bb7f3b02e22da2b0ab7280" }]
    }
  }
}

################################################################################
# 10-cluster-access.tf: who can reach the cluster.
#
# Three paths in, deliberately different: Identity Center permission sets (the
# front door), the break-glass role (for when Identity Center is what is
# broken), and var.additional_cluster_admin_arns (the escape hatch). All three
# end up as EKS access entries, built in locals.tf.
################################################################################

################################################################################
# Identity Center
################################################################################

run "no_sso_entries_when_none_are_configured" {
  command = apply

  # This is what terraform.tfvars actually sets today.
  variables {
    sso_access_permission_sets = {}
  }

  assert {
    condition     = length(local.sso_access_entries) == 0
    error_message = "An empty var.sso_access_permission_sets must produce no access entries."
  }

  # `cluster_creator` is the module's own entry for whichever identity ran the
  # apply (enable_cluster_creator_admin_permissions) -- in CI, the GitHub
  # Actions apply user.
  assert {
    condition     = toset(keys(module.eks.access_entries)) == toset(["break-glass", "cluster_creator"])
    error_message = "With no permission sets and the break-glass role on, break-glass and the cluster creator should be the only access entries."
  }
}

# Identity Center provisions its roles under
# /aws-reserved/sso.amazonaws.com/<region>/, and an EKS access entry must name
# the role WITHOUT that path. locals.tf rebuilds the ARN from the bare role name.
run "sso_role_arns_are_rebuilt_without_the_path" {
  command = apply

  variables {
    sso_access_permission_sets = {
      EKSClusterAdmin = { access_policy = "cluster-admin" }
    }
  }

  override_data {
    target = data.aws_iam_roles.sso_permission_sets["EKSClusterAdmin"]
    values = {
      arns = ["arn:aws:iam::111122223333:role/aws-reserved/sso.amazonaws.com/eu-west-1/AWSReservedSSO_EKSClusterAdmin_1a2b3c4d5e6f7890"]
    }
  }

  assert {
    condition     = local.sso_role_arns["EKSClusterAdmin"] == "arn:aws:iam::111122223333:role/AWSReservedSSO_EKSClusterAdmin_1a2b3c4d5e6f7890"
    error_message = "The Identity Center path must be stripped from the role ARN. A path-carrying ARN either fails to match the principal at authentication time or is silently normalised."
  }

  assert {
    condition     = local.sso_access_entries["sso-EKSClusterAdmin"].principal_arn == local.sso_role_arns["EKSClusterAdmin"]
    error_message = "The access entry does not point at the rebuilt role ARN."
  }
}

run "permission_sets_map_to_the_right_eks_policy_and_scope" {
  command = apply

  variables {
    sso_access_permission_sets = {
      EKSClusterAdmin = { access_policy = "cluster-admin" }
      EKSViewer       = { access_policy = "view" }
      AppTeam         = { access_policy = "edit", namespaces = ["counter-api"] }
    }
  }

  assert {
    condition     = local.sso_access_entries["sso-EKSClusterAdmin"].policy_associations["cluster-admin"].policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    error_message = "cluster-admin must map to AWS's AmazonEKSClusterAdminPolicy."
  }

  assert {
    condition     = local.sso_access_entries["sso-EKSViewer"].policy_associations["view"].policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
    error_message = "view must map to AmazonEKSViewPolicy."
  }

  # A permission set with no namespaces is cluster-wide; one with namespaces is
  # scoped to exactly those.
  assert {
    condition = (
      local.sso_access_entries["sso-EKSViewer"].policy_associations["view"].access_scope.type == "cluster" &&
      local.sso_access_entries["sso-EKSViewer"].policy_associations["view"].access_scope.namespaces == null
    )
    error_message = "A permission set with namespaces = null must be cluster-scoped, with no namespace list."
  }

  assert {
    condition = (
      local.sso_access_entries["sso-AppTeam"].policy_associations["edit"].access_scope.type == "namespace" &&
      tolist(local.sso_access_entries["sso-AppTeam"].policy_associations["edit"].access_scope.namespaces) == tolist(["counter-api"])
    )
    error_message = "A permission set with namespaces must produce a namespace-scoped access entry limited to them."
  }

  assert {
    condition     = toset(keys(module.eks.access_entries)) == toset(["sso-EKSClusterAdmin", "sso-EKSViewer", "sso-AppTeam", "break-glass", "cluster_creator"])
    error_message = "The set of access entries is not the three permission sets plus break-glass plus the cluster creator."
  }
}

# The `view` default exists so that adding a permission set without saying what
# it may do grants the least, not the most.
run "access_policy_defaults_to_view" {
  command = apply

  variables {
    sso_access_permission_sets = {
      SomeTeam = {}
    }
  }

  assert {
    condition     = keys(local.sso_access_entries["sso-SomeTeam"].policy_associations) == ["view"]
    error_message = "A permission set with no access_policy must default to view, not to something broader."
  }
}

################################################################################
# Variable validations
################################################################################

run "rejects_an_unknown_access_policy" {
  command = plan

  variables {
    sso_access_permission_sets = {
      Typo = { access_policy = "cluster-adminn" }
    }
  }

  expect_failures = [var.sso_access_permission_sets]
}

# AWS only allows AmazonEKSClusterAdminPolicy at cluster scope. Caught here
# rather than by the API mid-apply.
run "rejects_namespace_scoped_cluster_admin" {
  command = plan

  variables {
    sso_access_permission_sets = {
      Wrong = { access_policy = "cluster-admin", namespaces = ["counter-api"] }
    }
  }

  expect_failures = [var.sso_access_permission_sets]
}

run "rejects_session_duration_outside_the_aws_limits" {
  command = plan

  variables {
    break_glass_max_session_duration = 1800
  }

  expect_failures = [var.break_glass_max_session_duration]
}

run "rejects_session_duration_above_twelve_hours" {
  command = plan

  variables {
    break_glass_max_session_duration = 43201
  }

  expect_failures = [var.break_glass_max_session_duration]
}

################################################################################
# Break-glass role
################################################################################

run "break_glass_is_cluster_admin_and_short_lived" {
  command = apply

  assert {
    condition     = local.break_glass_access_entries["break-glass"].policy_associations["cluster-admin"].policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    error_message = "The break-glass role must map to cluster-admin -- it is the last way in when Identity Center is unavailable."
  }

  # An emergency session should not outlive the emergency.
  assert {
    condition     = aws_iam_role.break_glass[0].max_session_duration == 3600
    error_message = "The break-glass session duration is not the one-hour default."
  }

  assert {
    condition     = aws_iam_role.break_glass[0].tags["Access"] == "break-glass"
    error_message = "The break-glass role lost the tag that makes it findable in an audit."
  }
}

# The assume policy is attached to nobody by default: it is handed out during an
# incident and detached afterwards. It must also let the holder resolve the
# cluster endpoint, or the break-glass path fails before Kubernetes is reached.
run "break_glass_assume_policy_covers_the_whole_path_in" {
  command = apply

  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.break_glass[0].policy).Statement :
      s if s.Action == "sts:AssumeRole" && s.Resource == aws_iam_role.break_glass[0].arn
    ]) == 1
    error_message = "The assume policy must allow sts:AssumeRole on the break-glass role and nothing else."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.break_glass[0].policy).Statement :
      s if s.Action == "eks:DescribeCluster" && s.Resource == module.eks.cluster_arn
    ]) == 1
    error_message = "Without eks:DescribeCluster the CLI cannot write a kubeconfig, so the break-glass path fails before any Kubernetes permission comes into play."
  }

  assert {
    condition     = length(jsondecode(aws_iam_policy.break_glass[0].policy).Statement) == 2
    error_message = "The break-glass assume policy grew a third statement; it should stay exactly assume-role plus describe-cluster."
  }
}

run "break_glass_can_be_turned_off" {
  command = apply

  variables {
    break_glass_role_enabled = false
  }

  assert {
    condition     = length(aws_iam_role.break_glass) == 0 && length(aws_iam_policy.break_glass) == 0
    error_message = "break_glass_role_enabled = false must create neither the role nor its assume policy."
  }

  assert {
    condition     = length(local.break_glass_access_entries) == 0
    error_message = "A disabled break-glass role must not leave an access entry behind."
  }

  assert {
    condition     = output.cluster_access.break_glass == null
    error_message = "The cluster_access output should report break-glass as absent when it is disabled."
  }
}

# Empty trusted principals means the account root, which delegates the decision
# to the account's own IAM rather than making the trust policy the allow-list.
run "break_glass_trust_defaults_to_the_account_root" {
  command = apply

  assert {
    condition     = tolist(local.break_glass_trusted_principals) == tolist(["arn:aws:iam::111122223333:root"])
    error_message = "With var.break_glass_trusted_principals empty the trust policy should name the account root."
  }
}

run "break_glass_trust_can_be_narrowed" {
  command = apply

  variables {
    break_glass_trusted_principals = ["arn:aws:iam::111122223333:role/OnCall"]
  }

  assert {
    condition     = tolist(local.break_glass_trusted_principals) == tolist(["arn:aws:iam::111122223333:role/OnCall"])
    error_message = "An explicit principal list must replace the account-root default, not be added to it."
  }
}

################################################################################
# The escape hatch
################################################################################

run "additional_admin_arns_become_cluster_admin_entries" {
  command = apply

  variables {
    sso_access_permission_sets    = {}
    additional_cluster_admin_arns = ["arn:aws:iam::111122223333:role/ci-machine"]
  }

  # The key is the ARN with every non-alphanumeric character replaced, since an
  # access-entry map key cannot be an ARN.
  assert {
    condition     = contains(keys(module.eks.access_entries), "arn-aws-iam--111122223333-role-ci-machine")
    error_message = "An ARN in var.additional_cluster_admin_arns did not produce an access entry under its sanitised key."
  }

  assert {
    condition     = length(module.eks.access_entries) == 3
    error_message = "Expected exactly the one additional admin, plus break-glass and the cluster creator."
  }
}

run "the_cluster_access_output_reports_every_path_in" {
  command = apply

  variables {
    sso_access_permission_sets = {
      EKSViewer = { access_policy = "view" }
      AppTeam   = { access_policy = "admin", namespaces = ["counter-api", "monitoring"] }
    }
  }

  assert {
    condition     = output.cluster_access.sso["EKSViewer"].scope == "cluster-wide"
    error_message = "A permission set with no namespaces should be reported as cluster-wide."
  }

  assert {
    condition     = output.cluster_access.sso["AppTeam"].scope == "counter-api, monitoring"
    error_message = "A namespace-scoped permission set should list its namespaces in the output."
  }

  assert {
    condition     = output.cluster_access.break_glass.mfa_required == true
    error_message = "MFA on the break-glass role is on by default and the output should say so."
  }
}
