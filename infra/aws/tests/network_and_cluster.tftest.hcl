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
# 01-vpc.tf / 02-eks.tf.
#
# Assertions can only reach a module's OUTPUTS, never its internal resources,
# so what is checked here is the network shape and the cluster-level wiring the
# vpc/eks modules publish. Anything the modules keep to themselves (the node
# group's launch template, the addon install order) is not observable from a
# test and is not asserted.
################################################################################

run "naming_is_derived_from_project_and_environment" {
  command = plan

  assert {
    condition     = local.name_cluster == "chamo-dev-cluster" && local.name_vpc == "chamo-dev-vpc" && local.node_groups_name == "chamo-dev-ng"
    error_message = "Resource names must stay <project_name>-<environment>-*: bootstrap/main.tf scopes the CI apply user's IAM permissions to exactly that prefix."
  }

  # Karpenter selects subnets, security groups and its node role by this tag,
  # not by ID. It has to be the cluster name and nothing else.
  assert {
    condition     = local.karpenter_discovery_tag == local.name_cluster
    error_message = "The karpenter.sh/discovery tag value drifted from the cluster name."
  }

  assert {
    condition     = module.eks.cluster_name == "chamo-dev-cluster"
    error_message = "The cluster is not named local.name_cluster."
  }
}

run "renaming_the_project_moves_every_name_together" {
  command = plan

  variables {
    project_name = "acme"
    environment  = "prod"
  }

  # If any of these stopped tracking the prefix, the bootstrap apply user's
  # IAM scoping would no longer cover them.
  assert {
    condition = (
      local.name_cluster == "acme-prod-cluster" &&
      local.name_vpc == "acme-prod-vpc" &&
      local.node_groups_name == "acme-prod-ng" &&
      local.karpenter_discovery_tag == "acme-prod-cluster" &&
      aws_iam_role.aws_load_balancer_controller.name == "acme-prod-aws-load-balancer-controller" &&
      aws_iam_policy.aws_load_balancer_controller.name == "acme-prod-aws-load-balancer-controller" &&
      aws_iam_role.ebs_csi_driver.name == "acme-prod-ebs-csi-driver" &&
      aws_iam_role.break_glass[0].name == "acme-prod-eks-break-glass" &&
      aws_iam_policy.break_glass[0].name == "acme-prod-eks-break-glass-assume"
    )
    error_message = "Something this stack creates is no longer named <project_name>-<environment>-*. The CI apply user's IAM grants are scoped to that prefix in bootstrap/main.tf, so it would lose access to it."
  }
}

run "vpc_layout_matches_the_variables" {
  command = plan

  assert {
    condition     = module.vpc.vpc_cidr_block == "10.0.0.0/16"
    error_message = "The VPC CIDR is not var.vpc_cidr."
  }

  assert {
    condition     = module.vpc.private_subnets_cidr_blocks == tolist(["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"])
    error_message = "The private subnet CIDRs are not var.private_subnets, in order."
  }

  assert {
    condition     = module.vpc.public_subnets_cidr_blocks == tolist(["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"])
    error_message = "The public subnet CIDRs are not var.public_subnets, in order."
  }

  # local.azs slices the first three opt-in-not-required zones.
  assert {
    condition     = length(module.vpc.azs) == 3 && length(local.azs) == 3
    error_message = "Three AZs are expected."
  }

  # single_nat_gateway = true. One per AZ would roughly triple the NAT bill.
  assert {
    condition     = length(module.vpc.natgw_ids) == 1
    error_message = "More than one NAT gateway: single_nat_gateway is no longer in effect."
  }
}

# The load balancer controller places internet-facing NLBs by
# kubernetes.io/role/elb and internal ones by kubernetes.io/role/internal-elb.
# Karpenter picks the subnets for new nodes by karpenter.sh/discovery.
run "subnet_tags_drive_discovery" {
  command = plan

  assert {
    condition = alltrue([
      for s in module.vpc.private_subnet_objects :
      s.tags["karpenter.sh/discovery"] == "chamo-dev-cluster" &&
      s.tags["kubernetes.io/role/internal-elb"] == "1" &&
      s.tags["kubernetes.io/cluster/chamo-dev-cluster"] == "shared"
    ])
    error_message = "A private subnet is missing the Karpenter discovery tag or the ELB/cluster tags."
  }

  # This is what keeps Karpenter-provisioned nodes out of the public subnets,
  # and therefore off public IPs -- map_public_ip_on_launch is true there.
  assert {
    condition = alltrue([
      for s in module.vpc.public_subnet_objects : !contains(keys(s.tags), "karpenter.sh/discovery")
    ])
    error_message = "A public subnet carries karpenter.sh/discovery: Karpenter would be free to place nodes there, and those subnets launch instances with a public IP."
  }

  assert {
    condition = alltrue([
      for s in module.vpc.public_subnet_objects :
      s.tags["kubernetes.io/role/elb"] == "1" && s.tags["kubernetes.io/cluster/chamo-dev-cluster"] == "shared"
    ])
    error_message = "A public subnet is missing the tags an internet-facing NLB is placed by."
  }
}

run "cluster_version_tracks_the_variable" {
  command = plan

  assert {
    condition     = module.eks.cluster_version == "1.36"
    error_message = "The Kubernetes version is not var.cluster_version."
  }
}

run "cluster_version_is_configurable" {
  command = plan

  variables {
    cluster_version = "1.33"
  }

  assert {
    condition     = module.eks.cluster_version == "1.33"
    error_message = "var.cluster_version is not reaching the cluster."
  }
}

run "the_addon_set_is_what_replaces_auto_mode" {
  command = plan

  # With Auto Mode off (compute_config.enabled = false) nothing installs the
  # cluster's base components any more, so they are ordinary addons. Losing one
  # of these is a silent, specific outage rather than a failed apply.
  assert {
    condition = toset(keys(module.eks.cluster_addons)) == toset([
      "vpc-cni", "kube-proxy", "eks-pod-identity-agent",
      "coredns", "metrics-server", "aws-ebs-csi-driver",
    ])
    error_message = "The addon set changed. vpc-cni/kube-proxy missing means nodes join with no pod networking; eks-pod-identity-agent missing means Karpenter and the load balancer controller get no credentials; metrics-server missing means the counter-api and gateway HPAs never scale; aws-ebs-csi-driver missing means the VMSingle and Grafana PVCs stay Pending."
  }
}

################################################################################
# AWS Load Balancer Controller (09-load-balancer-controller.tf)
#
# A hard dependency of the whole Gateway API setup: without it every
# aws-load-balancer-* annotation in the repo is inert and the Gateways sit with
# no NLB and no address.
################################################################################

# `apply` rather than `plan`: the chart's values interpolate the cluster name
# and VPC id, which are only known once the resources exist. Nothing is called
# -- every provider in this file is a mock.
run "load_balancer_controller_credentials_are_pod_identity" {
  command = apply

  # The Pod Identity association is bound to an exact namespace/service account
  # pair, so the Helm chart has to be told to use the same name.
  assert {
    condition = (
      aws_eks_pod_identity_association.aws_load_balancer_controller.namespace == "kube-system" &&
      aws_eks_pod_identity_association.aws_load_balancer_controller.service_account == "aws-load-balancer-controller"
    )
    error_message = "The Pod Identity association does not match var.load_balancer_controller_namespace / _service_account."
  }

  assert {
    condition = (
      yamldecode(helm_release.aws_load_balancer_controller.values[0]).serviceAccount.name == aws_eks_pod_identity_association.aws_load_balancer_controller.service_account &&
      yamldecode(helm_release.aws_load_balancer_controller.values[0]).serviceAccount.create == true
    )
    error_message = "The chart's service account name drifted from the one the Pod Identity association is bound to -- the controller would run with no AWS credentials."
  }

  assert {
    condition     = helm_release.aws_load_balancer_controller.namespace == aws_eks_pod_identity_association.aws_load_balancer_controller.namespace
    error_message = "The chart is installed in a different namespace from the one the Pod Identity association names."
  }

  assert {
    condition     = yamldecode(helm_release.aws_load_balancer_controller.values[0]).region == "eu-west-1"
    error_message = "The controller is pointed at the wrong region."
  }
}

run "load_balancer_controller_chart_is_new_enough_for_pod_identity" {
  command = plan

  # Charts older than 3.0 need IRSA instead of the Pod Identity path used here.
  assert {
    condition     = tonumber(split(".", var.load_balancer_controller_chart_version)[0]) >= 3
    error_message = "aws-load-balancer-controller chart < 3.0 does not support the EKS Pod Identity credential path this config relies on; it would need an IRSA role instead."
  }
}
