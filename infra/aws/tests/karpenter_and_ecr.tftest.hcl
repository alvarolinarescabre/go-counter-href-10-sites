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
# 08-karpenter.tf and 07-ecr.tf.
#
# The NodePool and EC2NodeClass are the cost and capacity guard rails, and they
# only work if the discovery tags line up with the ones 01-vpc.tf and 02-eks.tf
# actually apply.
################################################################################

################################################################################
# EC2NodeClass: how Karpenter finds what to build nodes out of
################################################################################

run "node_class_discovers_by_the_cluster_tag" {
  command = apply

  assert {
    condition = (
      yamldecode(kubectl_manifest.karpenter_ec2_node_class.yaml_body).spec.subnetSelectorTerms[0].tags["karpenter.sh/discovery"] == "chamo-dev-cluster" &&
      yamldecode(kubectl_manifest.karpenter_ec2_node_class.yaml_body).spec.securityGroupSelectorTerms[0].tags["karpenter.sh/discovery"] == "chamo-dev-cluster"
    )
    error_message = "The EC2NodeClass selectors must match local.karpenter_discovery_tag, which is what tags the private subnets (01-vpc.tf) and the node security group (02-eks.tf). A mismatch leaves Karpenter unable to find anywhere to put a node."
  }

  # Nodes it launches carry the same tag, which is how they are recognised later.
  assert {
    condition     = yamldecode(kubectl_manifest.karpenter_ec2_node_class.yaml_body).spec.tags["karpenter.sh/discovery"] == "chamo-dev-cluster"
    error_message = "Provisioned nodes should carry the discovery tag."
  }

  # instanceProfile, NOT role. `spec.role` makes Karpenter create and manage
  # its own instance profile (<cluster>_<hash>) that Terraform never sees --
  # only Karpenter deletes it, and a teardown where Karpenter died first leaves
  # it holding the node role. The next apply recreates the role under the same
  # fixed name, the stale profile latches on, and the destroy after that fails
  # with "Cannot delete entity, must remove roles from instance profile first".
  assert {
    condition     = !can(yamldecode(kubectl_manifest.karpenter_ec2_node_class.yaml_body).spec.role)
    error_message = "spec.role is back: Karpenter will create an instance profile Terraform cannot delete."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.karpenter_ec2_node_class.yaml_body).spec.instanceProfile == module.karpenter.instance_profile_name
    error_message = "The EC2NodeClass must point at the instance profile the karpenter module owns, or Terraform is not the one deleting it."
  }

  assert {
    condition     = module.karpenter.node_iam_role_name == "chamo-dev-karpenter-node"
    error_message = "The Karpenter node role name is no longer <project>-<environment>-karpenter-node; node_iam_role_use_name_prefix = false is what keeps it stable."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.karpenter_ec2_node_class.yaml_body).spec.amiSelectorTerms[0].alias == "al2023@latest"
    error_message = "The AMI alias is not var.karpenter_node_ami_alias."
  }
}

################################################################################
# NodePool: what Karpenter is allowed to provision
################################################################################

run "node_pool_requirements_come_from_the_variables" {
  command = apply

  assert {
    condition = tolist([
      for r in yamldecode(kubectl_manifest.karpenter_node_pool.yaml_body).spec.template.spec.requirements :
      r.values if r.key == "karpenter.k8s.aws/instance-category"
    ][0]) == tolist(["c", "m", "r"])
    error_message = "The instance categories are not var.karpenter_node_instance_categories. Burstable \"t\" types run out of CPU credits under sustained load and add latency spikes."
  }

  assert {
    condition = tolist([
      for r in yamldecode(kubectl_manifest.karpenter_node_pool.yaml_body).spec.template.spec.requirements :
      r.values if r.key == "karpenter.sh/capacity-type"
    ][0]) == tolist(["spot", "on-demand"])
    error_message = "The capacity types are not var.karpenter_node_capacity_types."
  }

  # The counter-api image is built for linux/amd64 only; arm64 nodes would fail
  # to pull it.
  assert {
    condition = tolist([
      for r in yamldecode(kubectl_manifest.karpenter_node_pool.yaml_body).spec.template.spec.requirements :
      r.values if r.key == "kubernetes.io/arch"
    ][0]) == tolist(["amd64"])
    error_message = "The architecture list is not var.karpenter_node_architectures. Adding arm64 before CI publishes a multi-arch image gives nodes the image cannot run on."
  }

  # Karpenter's generation requirement is Gt, so the config has to pass
  # (minimum - 1) for "at least this generation" to mean what it says.
  assert {
    condition = tolist([
      for r in yamldecode(kubectl_manifest.karpenter_node_pool.yaml_body).spec.template.spec.requirements :
      r.values if r.key == "karpenter.k8s.aws/instance-generation"
    ][0]) == tolist(["2"])
    error_message = "The generation bound is off by one: the operator is Gt, so a minimum of 3 must be expressed as Gt 2."
  }

  assert {
    condition = alltrue([
      for r in yamldecode(kubectl_manifest.karpenter_node_pool.yaml_body).spec.template.spec.requirements :
      r.operator == "Gt" if r.key == "karpenter.k8s.aws/instance-generation"
    ])
    error_message = "The generation requirement is no longer a Gt comparison, so the minus-one above is now wrong."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.karpenter_node_pool.yaml_body).spec.template.spec.nodeClassRef.name == yamldecode(kubectl_manifest.karpenter_ec2_node_class.yaml_body).metadata.name
    error_message = "The NodePool references an EC2NodeClass that does not exist."
  }
}

run "generation_minimum_is_configurable" {
  command = apply

  variables {
    karpenter_node_instance_generations_min = 6
  }

  assert {
    condition = tolist([
      for r in yamldecode(kubectl_manifest.karpenter_node_pool.yaml_body).spec.template.spec.requirements :
      r.values if r.key == "karpenter.k8s.aws/instance-generation"
    ][0]) == tolist(["5"])
    error_message = "var.karpenter_node_instance_generations_min is not reaching the NodePool as (minimum - 1)."
  }
}

# The cost guard rail: without it a runaway ReplicaSet scales the AWS bill, not
# just the cluster.
run "node_pool_has_a_cpu_ceiling" {
  command = apply

  assert {
    condition     = yamldecode(kubectl_manifest.karpenter_node_pool.yaml_body).spec.limits.cpu == 32
    error_message = "The NodePool CPU limit is not var.karpenter_node_cpu_limit."
  }

  assert {
    condition     = can(yamldecode(kubectl_manifest.karpenter_node_pool.yaml_body).spec.limits.cpu)
    error_message = "The NodePool has no CPU ceiling at all."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.karpenter_node_pool.yaml_body).spec.disruption.consolidateAfter == "1m"
    error_message = "The consolidation delay is not var.karpenter_node_consolidation_after; nodes would sit idle longer than intended."
  }
}

run "cpu_ceiling_is_configurable" {
  command = apply

  variables {
    karpenter_node_cpu_limit = 8
  }

  assert {
    condition     = yamldecode(kubectl_manifest.karpenter_node_pool.yaml_body).spec.limits.cpu == 8
    error_message = "var.karpenter_node_cpu_limit is not reaching the NodePool."
  }
}

################################################################################
# Spot service-linked role
################################################################################

# EC2 needs the account-wide Spot service-linked role before it will launch a
# spot instance, and the Karpenter controller role may not create it on the fly
# (AuthFailure.ServiceLinkedRoleCreationNotPermitted).
run "spot_service_linked_role_follows_the_capacity_types" {
  command = apply

  assert {
    condition     = length(aws_iam_service_linked_role.spot) == 1
    error_message = "With spot in var.karpenter_node_capacity_types the Spot service-linked role must be created, or every spot launch fails with AuthFailure.ServiceLinkedRoleCreationNotPermitted."
  }

  assert {
    condition     = aws_iam_service_linked_role.spot[0].aws_service_name == "spot.amazonaws.com"
    error_message = "The service-linked role is for the wrong service."
  }
}

run "no_spot_service_linked_role_without_spot" {
  command = apply

  variables {
    karpenter_node_capacity_types = ["on-demand"]
  }

  # It is account-wide and may already exist for other reasons; creating it
  # when nothing needs it is how you get a conflict on apply.
  assert {
    condition     = length(aws_iam_service_linked_role.spot) == 0
    error_message = "The Spot service-linked role should only be created when spot capacity is actually allowed."
  }
}

################################################################################
# 07-ecr.tf
################################################################################

run "ecr_repository_rejects_overwrites" {
  command = apply

  # The pipeline tags every image sha-<commit>, which is unique by
  # construction, so an overwrite can only be a mistake. The flip side: nothing
  # may push a floating tag like `latest`.
  assert {
    condition     = aws_ecr_repository.counter_api.image_tag_mutability == "IMMUTABLE"
    error_message = "Mutable tags would let a second push silently replace the image a running Deployment references."
  }

  assert {
    condition     = aws_ecr_repository.counter_api.image_scanning_configuration[0].scan_on_push == true
    error_message = "scan_on_push is off."
  }

  # This stack is built to be torn down, and destroy fails on a repository that
  # still holds images.
  assert {
    condition     = aws_ecr_repository.counter_api.force_delete == true
    error_message = "Without force_delete, terraform destroy fails on a repository that still holds images."
  }

  assert {
    condition     = aws_ecr_repository.counter_api.name == "go-counter-href-10-sites"
    error_message = "The repository name must match ECR_REPOSITORY in the deploy workflow and the repository part of image.repository in the Helm values."
  }
}

run "ecr_lifecycle_rules_expire_in_the_right_order" {
  command = apply

  # Rules are evaluated in rulePriority order and an image is only matched by
  # the first rule that selects it.
  assert {
    condition = [
      for r in jsondecode(aws_ecr_lifecycle_policy.counter_api.policy).rules : r.rulePriority
    ] == [1, 2]
    error_message = "The lifecycle rules are not in ascending rulePriority order."
  }

  assert {
    condition = length([
      for r in jsondecode(aws_ecr_lifecycle_policy.counter_api.policy).rules :
      r if r.rulePriority == 1 &&
      r.selection.tagStatus == "untagged" &&
      r.selection.countType == "sinceImagePushed" &&
      r.selection.countUnit == "days" &&
      r.selection.countNumber == 1
    ]) == 1
    error_message = "Rule 1 should expire untagged images after var.ecr_untagged_expiry_days."
  }

  assert {
    condition = length([
      for r in jsondecode(aws_ecr_lifecycle_policy.counter_api.policy).rules :
      r if r.rulePriority == 2 &&
      r.selection.tagStatus == "tagged" &&
      contains(r.selection.tagPrefixList, "sha-") &&
      r.selection.countType == "imageCountMoreThan" &&
      r.selection.countNumber == 20
    ]) == 1
    error_message = "Rule 2 should keep the last var.ecr_keep_last_images sha- tagged builds. Expiring an image a running Deployment references breaks any pod that has to be rescheduled."
  }

  assert {
    condition = alltrue([
      for r in jsondecode(aws_ecr_lifecycle_policy.counter_api.policy).rules : r.action.type == "expire"
    ])
    error_message = "A lifecycle rule does something other than expire."
  }
}

run "ecr_retention_is_configurable" {
  command = apply

  variables {
    ecr_keep_last_images     = 50
    ecr_untagged_expiry_days = 7
  }

  assert {
    condition = length([
      for r in jsondecode(aws_ecr_lifecycle_policy.counter_api.policy).rules :
      r if r.rulePriority == 2 && r.selection.countNumber == 50
    ]) == 1
    error_message = "var.ecr_keep_last_images is not reaching the lifecycle policy."
  }

  assert {
    condition = length([
      for r in jsondecode(aws_ecr_lifecycle_policy.counter_api.policy).rules :
      r if r.rulePriority == 1 && r.selection.countNumber == 7
    ]) == 1
    error_message = "var.ecr_untagged_expiry_days is not reaching the lifecycle policy."
  }
}

run "the_ecr_url_in_the_output_is_the_one_the_lifecycle_policy_governs" {
  command = apply

  assert {
    condition     = aws_ecr_lifecycle_policy.counter_api.repository == aws_ecr_repository.counter_api.name
    error_message = "The lifecycle policy is attached to a different repository than the one this config creates."
  }

  assert {
    condition     = output.ecr_repository_url == aws_ecr_repository.counter_api.repository_url
    error_message = "The ecr_repository_url output does not report this repository. It has to be pasted verbatim into image.repository in the Helm values."
  }
}
