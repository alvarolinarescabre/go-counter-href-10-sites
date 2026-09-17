################################################################################
# The two policy documents.
#
# These are the guard rails the comments in main.tf argue for -- the scoping to
# the project prefix, the explicit Denies, the condition on
# CreateServiceLinkedRole. Each is asserted against the rendered JSON, so a
# statement that is quietly widened later fails here rather than in the account.
#
# The AWS provider renders aws_iam_policy_document locally, so these run with
# no credentials; Action/Resource collapse to a bare string when a statement has
# only one, hence the flatten() around every membership check.
################################################################################

provider "aws" {
  region                      = "eu-west-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "111122223333" }
}

override_data {
  target = data.aws_partition.current
  values = { partition = "aws" }
}

################################################################################
# Shared policy
################################################################################

run "shared_policy_grants_state_writes" {
  command = plan

  # use_lockfile = true in ../providers.tf makes even a read-only plan write and
  # delete terraform.tfstate.tflock. A truly read-only S3 grant here would make
  # every plan fail to acquire its lock.
  assert {
    condition = alltrue([
      for action in ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"] :
      contains(flatten([
        for s in jsondecode(data.aws_iam_policy_document.terraform_shared.json).Statement :
        s.Action if s.Sid == "TerraformState"
      ]), action)
    ])
    error_message = "The state grant must include PutObject and DeleteObject: native S3 locking writes a .tflock object on every run, including plans."
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(data.aws_iam_policy_document.terraform_shared.json).Statement :
      s.Resource if s.Sid == "TerraformState"
    ])) == toset(["arn:aws:s3:::chamo-terraform-state-2027", "arn:aws:s3:::chamo-terraform-state-2027/*"])
    error_message = "The state grant must be scoped to the state bucket and its objects only."
  }
}

run "shared_policy_allows_plan_time_sso_lookup" {
  command = plan

  # 10-cluster-access.tf reads data.aws_iam_roles at PLAN time, so the read-only
  # plan job needs this just as much as the apply job does.
  assert {
    condition = contains(flatten([
      for s in jsondecode(data.aws_iam_policy_document.terraform_shared.json).Statement :
      s.Action if s.Sid == "IdentityCenterRoleDiscovery"
    ]), "iam:ListRoles")
    error_message = "Without iam:ListRoles the plan job fails resolving the Identity Center permission sets."
  }
}

run "state_bucket_is_configurable" {
  command = plan

  variables {
    state_bucket = "some-other-bucket"
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(data.aws_iam_policy_document.terraform_shared.json).Statement :
      s.Resource if s.Sid == "TerraformState"
    ])) == toset(["arn:aws:s3:::some-other-bucket", "arn:aws:s3:::some-other-bucket/*"])
    error_message = "var.state_bucket is not reaching the state grant. It has to track the backend block in ../providers.tf."
  }
}

################################################################################
# Apply policy: scoping
################################################################################

run "iam_grants_are_scoped_to_the_project_prefix" {
  command = plan

  assert {
    condition = toset(flatten([
      for s in jsondecode(data.aws_iam_policy_document.terraform_apply.json).Statement :
      s.Resource if s.Sid == "ProjectIamResources"
      ])) == toset([
      "arn:aws:iam::111122223333:role/chamo-dev-*",
      "arn:aws:iam::111122223333:policy/chamo-dev-*",
      "arn:aws:iam::111122223333:instance-profile/chamo-dev-*",
    ])
    error_message = "The wildcard IAM actions must stay scoped to <project>-<environment>-* resources in this account."
  }

  # The scoping is the only thing standing between `iam:*Role*` and the whole
  # account's IAM.
  assert {
    condition = !contains(flatten([
      for s in jsondecode(data.aws_iam_policy_document.terraform_apply.json).Statement :
      s.Resource if s.Sid == "ProjectIamResources"
    ]), "*")
    error_message = "ProjectIamResources must never be granted on \"*\"."
  }
}

run "service_linked_role_grant_is_conditioned" {
  command = plan

  # This one IS on "*" -- AWS-owned roles live under /aws-service-role/ and
  # cannot match the project prefix. The condition is what stops it being a
  # general role-creation grant.
  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.terraform_apply.json).Statement :
      s if s.Sid == "ServiceLinkedRoles" && can(s.Condition.StringEquals["iam:AWSServiceName"])
    ]) == 1
    error_message = "iam:CreateServiceLinkedRole on \"*\" must carry an iam:AWSServiceName condition."
  }

  # Karpenter's spot instances need this one specifically (08-karpenter.tf
  # creates aws_iam_service_linked_role.spot).
  assert {
    condition = contains(flatten([
      for s in jsondecode(data.aws_iam_policy_document.terraform_apply.json).Statement :
      s.Condition.StringEquals["iam:AWSServiceName"] if s.Sid == "ServiceLinkedRoles"
    ]), "spot.amazonaws.com")
    error_message = "spot.amazonaws.com must stay in the allowed service list or Karpenter cannot launch spot capacity."
  }
}

################################################################################
# Apply policy: the Denies
################################################################################

run "apply_user_cannot_escalate_itself" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(data.aws_iam_policy_document.terraform_apply.json).Statement :
      s if s.Sid == "DenySelfEscalation" && s.Effect == "Deny"
    ]) == 1
    error_message = "DenySelfEscalation is missing or no longer a Deny -- without it iam:*Role*/iam:*Policy* could be aimed at the CI users themselves."
  }

  assert {
    condition = alltrue([
      for action in ["iam:*User*", "iam:*AccessKey*", "iam:*LoginProfile*", "iam:*Group*"] :
      contains(flatten([
        for s in jsondecode(data.aws_iam_policy_document.terraform_apply.json).Statement :
        s.Action if s.Sid == "DenySelfEscalation"
      ]), action)
    ])
    error_message = "The self-escalation Deny must cover users, access keys, login profiles and groups."
  }
}

run "apply_user_cannot_rewrite_its_own_policies" {
  command = plan

  assert {
    condition = toset(flatten([
      for s in jsondecode(data.aws_iam_policy_document.terraform_apply.json).Statement :
      s.Resource if s.Sid == "DenyBootstrapPolicyChanges"
      ])) == toset([
      "arn:aws:iam::111122223333:policy/chamo-dev-terraform-shared",
      "arn:aws:iam::111122223333:policy/chamo-dev-terraform-apply",
    ])
    error_message = "The Deny must name both policies this root creates -- and their names must match aws_iam_policy.*.name, which is asserted in ci_users.tftest.hcl."
  }

  assert {
    condition = alltrue([
      for action in ["iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion"] :
      contains(flatten([
        for s in jsondecode(data.aws_iam_policy_document.terraform_apply.json).Statement :
        s.Action if s.Sid == "DenyBootstrapPolicyChanges"
      ]), action)
    ])
    error_message = "Every way of editing a policy in place must be denied, not just DeletePolicy."
  }
}

################################################################################
# The prefix contract with the main stack
################################################################################

# main.tf's scoping only works because the main stack names everything
# `<project_name>-<environment>-*`. Changing either variable must move the whole
# prefix, in both policies, or the apply user silently loses access to the
# resources it is supposed to manage.
run "project_and_environment_move_the_whole_prefix" {
  command = plan

  variables {
    project_name = "acme"
    environment  = "prod"
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(data.aws_iam_policy_document.terraform_apply.json).Statement :
      s.Resource if s.Sid == "ProjectIamResources"
      ])) == toset([
      "arn:aws:iam::111122223333:role/acme-prod-*",
      "arn:aws:iam::111122223333:policy/acme-prod-*",
      "arn:aws:iam::111122223333:instance-profile/acme-prod-*",
    ])
    error_message = "The IAM scoping did not follow project_name/environment."
  }

  assert {
    condition     = aws_iam_policy.terraform_apply.name == "acme-prod-terraform-apply" && aws_iam_policy.terraform_shared.name == "acme-prod-terraform-shared"
    error_message = "The policy names did not follow project_name/environment."
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(data.aws_iam_policy_document.terraform_apply.json).Statement :
      s.Resource if s.Sid == "DenyBootstrapPolicyChanges"
      ])) == toset([
      "arn:aws:iam::111122223333:policy/acme-prod-terraform-shared",
      "arn:aws:iam::111122223333:policy/acme-prod-terraform-apply",
    ])
    error_message = "DenyBootstrapPolicyChanges stopped naming the policies this root actually creates -- the guard rail is now pointing at nothing."
  }
}

# Nothing may hardcode "arn:aws:"; the ARNs are built from data.aws_partition.
run "partition_is_not_hardcoded" {
  command = plan

  variables {
    state_bucket = "gov-state"
  }

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws-us-gov" }
  }

  assert {
    condition = contains(flatten([
      for s in jsondecode(data.aws_iam_policy_document.terraform_shared.json).Statement :
      s.Resource if s.Sid == "TerraformState"
    ]), "arn:aws-us-gov:s3:::gov-state")
    error_message = "The state bucket ARN hardcodes the aws partition."
  }

  assert {
    condition = alltrue([
      for r in flatten([
        for s in jsondecode(data.aws_iam_policy_document.terraform_apply.json).Statement :
        s.Resource if s.Sid == "ProjectIamResources"
      ]) : startswith(r, "arn:aws-us-gov:iam::")
    ])
    error_message = "The project IAM ARNs hardcode the aws partition."
  }

  assert {
    condition     = aws_iam_user_policy_attachment.plan_read_only.policy_arn == "arn:aws-us-gov:iam::aws:policy/ReadOnlyAccess"
    error_message = "The managed-policy ARN hardcodes the aws partition."
  }
}
