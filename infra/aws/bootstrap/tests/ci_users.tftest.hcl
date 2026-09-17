################################################################################
# The two CI users, their attachments and their access keys.
#
# `command = plan` throughout: nothing here needs a real account, so the AWS
# provider is configured with dummy credentials and every validation/metadata
# call switched off. The two data sources that DO call AWS are overridden.
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

run "defaults_create_both_users" {
  command = plan

  assert {
    condition     = aws_iam_user.ci["plan"].name == "gha-counter-api-terraform-plan"
    error_message = "The plan user's default name is what the setup docs used; changing it breaks `terraform import` adoption of an existing user."
  }

  assert {
    condition     = aws_iam_user.ci["apply"].name == "gha-counter-api-terraform-apply"
    error_message = "The apply user's default name changed."
  }

  assert {
    condition     = length(aws_iam_user.ci) == 2
    error_message = "Exactly two CI users are expected: one for the read-only plan job, one for the reviewer-gated apply job."
  }
}

# The privilege split is the whole point of this root: the automatic
# plan-on-main job must never hold the write policy.
run "plan_user_is_read_only" {
  command = plan

  assert {
    condition     = aws_iam_user_policy_attachment.plan_read_only.user == aws_iam_user.ci["plan"].name
    error_message = "ReadOnlyAccess must be attached to the plan user."
  }

  assert {
    condition     = aws_iam_user_policy_attachment.plan_read_only.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "The plan user should carry AWS's own ReadOnlyAccess, not a hand-rolled Describe*/List*/Get* list."
  }

  assert {
    condition     = aws_iam_user_policy_attachment.terraform_apply.user == aws_iam_user.ci["apply"].name
    error_message = "The write policy is attached to a user other than the apply user -- the plan job must stay read-only."
  }
}

run "apply_user_has_read_and_write" {
  command = plan

  assert {
    condition     = aws_iam_user_policy_attachment.apply_read_only.user == aws_iam_user.ci["apply"].name
    error_message = "An apply starts by refreshing state, which needs the same reads the plan user does."
  }

  # The policy ARN itself is only known after apply, so this pins the name the
  # ARN is built from instead.
  assert {
    condition     = aws_iam_policy.terraform_apply.name == "chamo-dev-terraform-apply"
    error_message = "The write policy's name changed; the apply policy's own DenyBootstrapPolicyChanges statement names it literally."
  }
}

# Both jobs write the .tflock object and both resolve the Identity Center roles
# at plan time, so the shared policy goes on both users.
run "shared_policy_on_both_users" {
  command = plan

  assert {
    condition     = length(aws_iam_user_policy_attachment.terraform_shared) == 2
    error_message = "The shared policy must be attached to both CI users."
  }

  assert {
    condition = alltrue([
      for k, a in aws_iam_user_policy_attachment.terraform_shared : a.user == aws_iam_user.ci[k].name
    ])
    error_message = "A shared-policy attachment points at the wrong user."
  }

  assert {
    condition     = aws_iam_policy.terraform_shared.name == "chamo-dev-terraform-shared"
    error_message = "The shared policy's name changed; DenyBootstrapPolicyChanges in the apply policy names it literally."
  }
}

run "no_access_keys_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_access_key.ci) == 0
    error_message = "create_access_keys defaults to false so the secret never lands in this root's local state file."
  }
}

run "access_keys_when_opted_in" {
  command = plan

  variables {
    create_access_keys = true
  }

  assert {
    condition     = length(aws_iam_access_key.ci) == 2
    error_message = "With create_access_keys = true both users should get a key."
  }

  assert {
    condition = alltrue([
      for k, key in aws_iam_access_key.ci : key.user == aws_iam_user.ci[k].name
    ])
    error_message = "An access key is attached to the wrong user."
  }
}

run "user_names_are_configurable" {
  command = plan

  variables {
    plan_user_name  = "ci-plan"
    apply_user_name = "ci-apply"
  }

  assert {
    condition     = aws_iam_user.ci["plan"].name == "ci-plan" && aws_iam_user.ci["apply"].name == "ci-apply"
    error_message = "var.plan_user_name / var.apply_user_name are not reaching the users."
  }

  assert {
    condition     = aws_iam_user_policy_attachment.terraform_apply.user == "ci-apply"
    error_message = "Renaming the users must not move the write policy onto the plan user."
  }
}
