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
# 12-keda.tf: the KEDA install.
#
# Terraform only creates the Argo CD Application; the ScaledObject that
# actually scales counter-api lives in the application chart. So what is worth
# asserting here is the handful of settings that make the difference between
# KEDA working and KEDA looking installed but breaking on first use.
################################################################################

run "keda_is_installed_as_an_argocd_application" {
  command = apply

  assert {
    condition     = length(kubectl_manifest.keda) == 1
    error_message = "enable_keda defaults to true, so the Argo CD Application should exist."
  }

  assert {
    condition = (
      yamldecode(kubectl_manifest.keda[0].yaml_body).spec.source.repoURL == "https://kedacore.github.io/charts" &&
      yamldecode(kubectl_manifest.keda[0].yaml_body).spec.source.chart == "keda" &&
      yamldecode(kubectl_manifest.keda[0].yaml_body).spec.source.targetRevision == "2.20.2"
    )
    error_message = "The chart coordinates are not the kedacore chart at var.keda_chart_version."
  }

  assert {
    condition = (
      yamldecode(kubectl_manifest.keda[0].yaml_body).metadata.namespace == "argocd" &&
      yamldecode(kubectl_manifest.keda[0].yaml_body).spec.destination.namespace == "keda"
    )
    error_message = "The Application must live in the Argo CD namespace and target var.keda_namespace."
  }

  # Nothing else creates the namespace, unlike monitoring.
  assert {
    condition     = contains(yamldecode(kubectl_manifest.keda[0].yaml_body).spec.syncPolicy.syncOptions, "CreateNamespace=true")
    error_message = "Without CreateNamespace the first sync fails: no resource creates var.keda_namespace."
  }

  # The ScaledJob CRD alone is past the 262 KiB last-applied-configuration
  # annotation limit of client-side apply.
  assert {
    condition     = contains(yamldecode(kubectl_manifest.keda[0].yaml_body).spec.syncPolicy.syncOptions, "ServerSideApply=true")
    error_message = "Without ServerSideApply the KEDA CRDs exceed the client-side apply annotation limit."
  }

  # A delete that leaves the ValidatingWebhookConfiguration behind points it at
  # a Service that no longer exists, and every ScaledObject write afterwards is
  # rejected cluster-wide.
  assert {
    condition     = contains(yamldecode(kubectl_manifest.keda[0].yaml_body).metadata.finalizers, "resources-finalizer.argocd.argoproj.io")
    error_message = "Without the finalizer, deleting the Application leaves the CRDs and webhooks orphaned."
  }
}

# The operator mints the serving certificates itself and patches the caBundle
# into these two objects, which the chart renders empty. Without both the
# ignoreDifferences entries and RespectIgnoreDifferences, selfHeal wipes the
# caBundle on every sync and KEDA breaks until the operator patches it back.
run "operator_patched_certificates_survive_a_sync" {
  command = apply

  assert {
    condition     = contains(yamldecode(kubectl_manifest.keda[0].yaml_body).spec.syncPolicy.syncOptions, "RespectIgnoreDifferences=true")
    error_message = "RespectIgnoreDifferences is what makes the ignoreDifferences entries below apply during a sync."
  }

  # keda-admission carries six webhook entries, each with its own caBundle, so
  # a fixed /webhooks/0 jsonPointer would cover only the first.
  assert {
    condition = length([
      for d in yamldecode(kubectl_manifest.keda[0].yaml_body).spec.ignoreDifferences :
      d if d.kind == "ValidatingWebhookConfiguration" &&
      d.name == "keda-admission" &&
      contains(d.jqPathExpressions, ".webhooks[].clientConfig.caBundle")
    ]) == 1
    error_message = "Every webhook entry's caBundle must be ignored, not just the first one."
  }

  assert {
    condition = length([
      for d in yamldecode(kubectl_manifest.keda[0].yaml_body).spec.ignoreDifferences :
      d if d.kind == "APIService" &&
      d.name == "v1beta1.external.metrics.k8s.io" &&
      contains(d.jsonPointers, "/spec/caBundle")
    ]) == 1
    error_message = "The aggregated APIService's caBundle must be ignored, or the external metrics API stops serving after a sync."
  }
}

# While the aggregated apiserver is unreachable, every ScaledObject-backed HPA
# reports "unable to fetch metrics" and holds its replica count. With Karpenter
# on spot that would happen on every reclaim of a single-replica deployment.
run "metrics_apiserver_is_not_a_single_point_of_failure" {
  command = apply

  assert {
    condition     = yamldecode(kubectl_manifest.keda[0].yaml_body).spec.source.helm.valuesObject.metricsServer.replicaCount == 2
    error_message = "One metrics apiserver replica means the external metrics API disappears with its node."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.keda[0].yaml_body).spec.source.helm.valuesObject.podDisruptionBudget.metricServer.minAvailable == 1
    error_message = "Without the PDB, consolidation can drain both apiserver replicas at once and the second replica buys nothing."
  }

  # cert-manager is not installed in this cluster, so the operator has to mint
  # its own certificates -- the other half of the ignoreDifferences above.
  assert {
    condition     = yamldecode(kubectl_manifest.keda[0].yaml_body).spec.source.helm.valuesObject.certificates.autoGenerated == true
    error_message = "With autoGenerated off and no cert-manager, the webhooks come up with no serving certificate."
  }
}

# The counter-api chart renders its ScaledObject only when keda.sh/v1alpha1 is
# a registered API, and with autoscaling.keda.enabled it renders no plain HPA
# either. Handing the application to Argo CD before KEDA has synced therefore
# leaves the Deployment with no autoscaler at all until the next reconcile.
run "the_application_waits_for_kedas_crds" {
  command = apply

  assert {
    condition     = length(time_sleep.wait_for_keda_crds) == 1
    error_message = "The barrier the counter-api Application depends on must exist whenever KEDA is installed."
  }

  assert {
    condition     = time_sleep.wait_for_keda_crds[0].create_duration == "120s"
    error_message = "The wait is not var.keda_sync_wait."
  }
}

run "keda_can_be_turned_off" {
  command = apply

  variables {
    enable_keda = false
  }

  assert {
    condition = (
      length(kubectl_manifest.keda) == 0 &&
      length(time_sleep.wait_for_keda_crds) == 0
    )
    error_message = "enable_keda = false must create neither the Application nor the barrier."
  }
}
