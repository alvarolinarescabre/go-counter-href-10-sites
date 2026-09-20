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
# 11-monitoring.tf: VictoriaMetrics, Grafana, and the storage underneath them.
#
# The stack is handed to Argo CD as an Application, so most of what is asserted
# here is the valuesObject Argo CD will render the chart with -- a wrong value
# there is not an apply failure, it is a cluster that comes up subtly wrong.
################################################################################

################################################################################
# Storage
################################################################################

# With Auto Mode off nothing provisions EBS volumes: the only StorageClass left
# is the legacy in-tree gp2 one, which no longer works on current Kubernetes.
run "gp3_is_the_default_storage_class" {
  command = apply

  assert {
    condition     = yamldecode(kubectl_manifest.gp3_storage_class.yaml_body).metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true"
    error_message = "gp3 must be the default StorageClass, so a chart that leaves storageClassName unset still gets a working volume."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.gp3_storage_class.yaml_body).provisioner == "ebs.csi.aws.com"
    error_message = "The StorageClass is not provisioned by the EBS CSI driver."
  }

  # The volume has to be created in the AZ the pod is actually scheduled to.
  assert {
    condition     = yamldecode(kubectl_manifest.gp3_storage_class.yaml_body).volumeBindingMode == "WaitForFirstConsumer"
    error_message = "Immediate binding creates the volume before the pod is scheduled, which can land it in an AZ the pod cannot run in."
  }

  assert {
    condition = (
      yamldecode(kubectl_manifest.gp3_storage_class.yaml_body).parameters.encrypted == "true" &&
      yamldecode(kubectl_manifest.gp3_storage_class.yaml_body).parameters.type == "gp3"
    )
    error_message = "Monitoring volumes should be encrypted gp3."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.gp3_storage_class.yaml_body).allowVolumeExpansion == true
    error_message = "Without allowVolumeExpansion, growing the VMSingle volume means recreating it."
  }
}

# The StorageClass and the CSI role are not part of the monitoring toggle: the
# cluster needs a working default StorageClass whether or not Grafana is on.
run "storage_survives_monitoring_being_turned_off" {
  command = apply

  variables {
    enable_monitoring = false
  }

  assert {
    condition     = yamldecode(kubectl_manifest.gp3_storage_class.yaml_body).metadata.name == "gp3"
    error_message = "The gp3 StorageClass must exist regardless of var.enable_monitoring -- it is the cluster's only way to provision a volume."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.ebs_csi_driver.policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    error_message = "The EBS CSI driver role lost the AWS-managed policy it needs to create volumes."
  }
}

################################################################################
# The VictoriaMetrics stack, as Argo CD will render it
################################################################################

run "vmsingle_storage_comes_from_the_variables" {
  command = apply

  assert {
    condition     = local.victoria_metrics_k8s_stack_values.vmsingle.spec.retentionPeriod == "15d"
    error_message = "The retention period is not var.monitoring_retention."
  }

  assert {
    condition = (
      local.victoria_metrics_k8s_stack_values.vmsingle.spec.storage.storageClassName == "gp3" &&
      local.victoria_metrics_k8s_stack_values.vmsingle.spec.storage.resources.requests.storage == "20Gi"
    )
    error_message = "VMSingle must land on the gp3 StorageClass at var.monitoring_storage_size."
  }

  assert {
    condition     = tolist(local.victoria_metrics_k8s_stack_values.vmsingle.spec.storage.accessModes) == tolist(["ReadWriteOnce"])
    error_message = "An EBS volume is ReadWriteOnce; anything else will never bind."
  }
}

run "monitoring_storage_is_configurable" {
  command = apply

  variables {
    monitoring_retention    = "30d"
    monitoring_storage_size = "50Gi"
  }

  assert {
    condition = (
      local.victoria_metrics_k8s_stack_values.vmsingle.spec.retentionPeriod == "30d" &&
      local.victoria_metrics_k8s_stack_values.vmsingle.spec.storage.resources.requests.storage == "50Gi"
    )
    error_message = "The monitoring retention/size variables are not reaching the chart values."
  }
}

run "components_that_would_only_burn_capacity_are_off" {
  command = apply

  # EKS runs the control plane outside the cluster: these endpoints do not
  # exist, and scraping them only produces permanently-down targets.
  assert {
    condition = (
      local.victoria_metrics_k8s_stack_values.kubeControllerManager.enabled == false &&
      local.victoria_metrics_k8s_stack_values.kubeScheduler.enabled == false &&
      local.victoria_metrics_k8s_stack_values.kubeEtcd.enabled == false
    )
    error_message = "Control-plane scrape targets must stay off on EKS -- there is nothing behind them but permanently-down targets."
  }

  # No notification receivers are configured yet.
  assert {
    condition = (
      local.victoria_metrics_k8s_stack_values.alertmanager.enabled == false &&
      local.victoria_metrics_k8s_stack_values.vmalert.enabled == false
    )
    error_message = "Alertmanager/vmalert are on but nothing is configured to receive from them."
  }

  # The webhook's certificate is generated with genCA on every chart render,
  # which Argo CD would see as permanent drift.
  assert {
    condition     = local.victoria_metrics_k8s_stack_values["victoria-metrics-operator"].admissionWebhooks.enabled == false
    error_message = "The operator's admission webhook regenerates its CA on every render, which Argo CD reports as permanent drift."
  }

  # A DaemonSet pod has to fit on every node, including system nodes already at
  # their max-pods limit.
  assert {
    condition     = local.victoria_metrics_k8s_stack_values["prometheus-node-exporter"].priorityClassName == "system-node-critical"
    error_message = "Without a system-critical priority the node exporter cannot preempt its way onto a full node, leaving that node unmonitored."
  }
}

# The parent chart enables the operator's CRD cleanup hook (the operator
# subchart defaults it off), and it cannot work at this release name: the hook
# Job is <release>-victoria-metrics-operator-cleanup-hook, 65 characters, and
# Kubernetes copies that into the pod template's automatic `job-name` label,
# where a value may not exceed 63 bytes. The API server rejects the Job, Argo
# CD retries the PreDelete hook forever, and the Application never finishes
# terminating -- which with `wait = true` fails the destroy outright.
run "the_crd_cleanup_hook_that_cannot_run_is_off" {
  command = apply

  assert {
    condition     = local.victoria_metrics_k8s_stack_values["victoria-metrics-operator"].crds.cleanup.enabled == false
    error_message = "The operator's CRD cleanup hook is on again; its Job name exceeds the 63-byte label limit at this release name and deadlocks the Application delete."
  }

  # The release name is what makes the hook name too long, so a rename is the
  # other way out of this -- and would silently rename the Grafana secret that
  # the ignoreDifferences entry and outputs.tf both refer to by name.
  assert {
    condition     = yamldecode(kubectl_manifest.victoria_metrics_k8s_stack[0].yaml_body).metadata.name == "victoria-metrics-k8s-stack"
    error_message = "The release name changed. Re-check the hook name length, the Grafana secret name in ignoreDifferences, and outputs.tf."
  }
}

# VMSingle and VMAgent carry apps.victoriametrics.com/finalizer and only the
# operator clears it. Argo CD's prune has no ordering of its own, so without
# this it removed the operator alongside the custom resources it was supposed
# to finalize -- wedging the namespace, and through it the Grafana NLB, the
# internet gateway detach and the subnet deletes.
run "the_operator_is_pruned_after_the_resources_it_finalizes" {
  command = apply

  assert {
    condition     = local.victoria_metrics_k8s_stack_values["victoria-metrics-operator"].annotations["argocd.argoproj.io/sync-options"] == "PruneLast=true"
    error_message = "Without PruneLast the operator can be pruned before VMSingle/VMAgent, leaving apps.victoriametrics.com/finalizer with nothing left alive to clear it."
  }
}

run "argocd_application_is_configured_for_the_charts_quirks" {
  command = apply

  assert {
    condition     = length(kubectl_manifest.victoria_metrics_k8s_stack) == 1
    error_message = "enable_monitoring defaults to true, so the Argo CD Application should exist."
  }

  # The operator CRDs exceed the 262 KiB last-applied-configuration annotation
  # limit of client-side apply.
  assert {
    condition     = contains(yamldecode(kubectl_manifest.victoria_metrics_k8s_stack[0].yaml_body).spec.syncPolicy.syncOptions, "ServerSideApply=true")
    error_message = "Without ServerSideApply the operator CRDs exceed the client-side apply annotation limit."
  }

  # The Grafana chart generates a random admin password on every render; without
  # these two, Argo CD rewrites the Secret on every sync and the password stored
  # in Grafana's database on first start no longer matches.
  assert {
    condition     = contains(yamldecode(kubectl_manifest.victoria_metrics_k8s_stack[0].yaml_body).spec.syncPolicy.syncOptions, "RespectIgnoreDifferences=true")
    error_message = "RespectIgnoreDifferences is what makes the ignoreDifferences entry below actually apply during a sync."
  }

  assert {
    condition = length([
      for d in yamldecode(kubectl_manifest.victoria_metrics_k8s_stack[0].yaml_body).spec.ignoreDifferences :
      d if d.kind == "Secret" &&
      d.name == "victoria-metrics-k8s-stack-grafana" &&
      contains(d.jsonPointers, "/data/admin-password")
    ]) == 1
    error_message = "The Grafana admin password must be ignored, or every sync rotates it out from under the running Grafana."
  }

  assert {
    condition = (
      yamldecode(kubectl_manifest.victoria_metrics_k8s_stack[0].yaml_body).spec.destination.namespace == "monitoring" &&
      yamldecode(kubectl_manifest.victoria_metrics_k8s_stack[0].yaml_body).metadata.namespace == "argocd"
    )
    error_message = "The Application must live in the Argo CD namespace and target var.monitoring_namespace."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.victoria_metrics_k8s_stack[0].yaml_body).spec.source.targetRevision == "0.92.1"
    error_message = "The chart version is not var.victoria_metrics_k8s_stack_chart_version."
  }

  assert {
    condition = (
      yamldecode(kubectl_manifest.victoria_metrics_k8s_stack[0].yaml_body).spec.syncPolicy.automated.prune == true &&
      yamldecode(kubectl_manifest.victoria_metrics_k8s_stack[0].yaml_body).spec.syncPolicy.automated.selfHeal == true
    )
    error_message = "The Application should self-heal and prune like the rest of the GitOps setup."
  }
}

run "grafana_persistence_and_rollout_strategy" {
  command = apply

  # The RWO volume cannot be attached to the old and the new pod at once, so a
  # rolling update deadlocks.
  assert {
    condition     = local.victoria_metrics_k8s_stack_values.grafana.deploymentStrategy.type == "Recreate"
    error_message = "Grafana holds a ReadWriteOnce volume; a RollingUpdate blocks forever waiting for a volume the outgoing pod still holds."
  }

  assert {
    condition = (
      local.victoria_metrics_k8s_stack_values.grafana.persistence.enabled == true &&
      local.victoria_metrics_k8s_stack_values.grafana.persistence.storageClassName == "gp3"
    )
    error_message = "Grafana's dashboards and users live on its volume; without persistence they are lost on every restart."
  }
}

################################################################################
# Grafana's route
################################################################################

run "grafana_gateway_and_route_by_default" {
  command = apply

  assert {
    condition     = length(kubectl_manifest.grafana_gateway) == 1 && length(kubectl_manifest.grafana_gateway_parameters) == 1
    error_message = "enable_grafana_route defaults to true, so Grafana gets its own Gateway and NLB."
  }

  assert {
    condition = (
      yamldecode(kubectl_manifest.grafana_gateway[0].yaml_body).metadata.namespace == "monitoring" &&
      yamldecode(kubectl_manifest.grafana_gateway_parameters[0].yaml_body).metadata.namespace == "monitoring"
    )
    error_message = "The Grafana Gateway and its parameters must both be in the monitoring namespace; parametersRef is a local reference."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.grafana_gateway[0].yaml_body).spec.infrastructure.parametersRef.name == yamldecode(kubectl_manifest.grafana_gateway_parameters[0].yaml_body).metadata.name
    error_message = "The Grafana Gateway references GatewayParameters that do not exist."
  }

  # The HTTPRoute comes from the Grafana chart, not from Terraform, so its
  # parentRef has to name the Gateway Terraform creates.
  assert {
    condition = (
      local.victoria_metrics_k8s_stack_values.grafana.route.main.enabled == true &&
      local.victoria_metrics_k8s_stack_values.grafana.route.main.parentRefs[0].name == local.grafana_gateway_name &&
      local.victoria_metrics_k8s_stack_values.grafana.route.main.parentRefs[0].sectionName == "http"
    )
    error_message = "The chart-rendered HTTPRoute does not point at the Gateway Terraform creates for it."
  }

  # group/kind spelled out: the API server defaults them, and leaving them
  # implicit makes Argo CD report the route as OutOfSync forever.
  assert {
    condition = (
      local.victoria_metrics_k8s_stack_values.grafana.route.main.parentRefs[0].group == "gateway.networking.k8s.io" &&
      local.victoria_metrics_k8s_stack_values.grafana.route.main.parentRefs[0].kind == "Gateway"
    )
    error_message = "parentRefs must spell out group and kind; the API server defaults them and Argo CD then reports permanent drift."
  }

  assert {
    condition     = tolist(local.victoria_metrics_k8s_stack_values.grafana.route.main.hostnames) == tolist(["grafana.alvarolinarescabre.com"])
    error_message = "The Grafana route should match var.grafana_hostname."
  }

  assert {
    condition     = local.victoria_metrics_k8s_stack_values.grafana["grafana.ini"].server.root_url == "http://grafana.alvarolinarescabre.com/"
    error_message = "Grafana's root_url must match the hostname it is reached on, or its redirects and asset URLs point elsewhere."
  }
}

run "empty_grafana_hostname_matches_any_host" {
  command = apply

  variables {
    grafana_hostname = ""
  }

  assert {
    condition     = length(local.victoria_metrics_k8s_stack_values.grafana.route.main.hostnames) == 0
    error_message = "An empty grafana_hostname must produce no hostnames, which is how Gateway API spells \"any Host\"."
  }

  # With no fixed hostname, root_url has to be resolved by Grafana at runtime
  # rather than baked in.
  assert {
    condition     = local.victoria_metrics_k8s_stack_values.grafana["grafana.ini"].server.root_url == "%(protocol)s://%(domain)s:%(http_port)s/"
    error_message = "With no hostname, root_url must fall back to Grafana's own runtime placeholders."
  }
}

run "grafana_route_can_be_turned_off" {
  command = apply

  variables {
    enable_grafana_route = false
  }

  assert {
    condition     = length(kubectl_manifest.grafana_gateway) == 0 && length(kubectl_manifest.grafana_gateway_parameters) == 0
    error_message = "enable_grafana_route = false must not provision a Gateway or its NLB."
  }

  assert {
    condition     = local.victoria_metrics_k8s_stack_values.grafana.route.main.enabled == false
    error_message = "The chart must also stop rendering the HTTPRoute, or it would reference a Gateway that no longer exists."
  }
}

################################################################################
# The monitoring toggle
################################################################################

run "monitoring_off_removes_everything_it_owns" {
  command = apply

  variables {
    enable_monitoring = false
  }

  assert {
    condition = (
      length(kubectl_manifest.monitoring_namespace) == 0 &&
      length(kubectl_manifest.victoria_metrics_k8s_stack) == 0 &&
      length(kubectl_manifest.counter_api_dashboard) == 0
    )
    error_message = "enable_monitoring = false must create no namespace, no Application and no dashboard."
  }

  # enable_grafana_route is still true by default here: the Gateway must follow
  # the monitoring toggle too, or an NLB is left behind with nothing behind it.
  assert {
    condition     = length(kubectl_manifest.grafana_gateway) == 0
    error_message = "With monitoring off, the Grafana Gateway (and its NLB) must go too -- there would be no Grafana behind it."
  }

  assert {
    condition     = strcontains(output.instructions, "Disabled (enable_monitoring = false)")
    error_message = "The instructions output should say monitoring is off."
  }
}

run "monitoring_namespace_is_configurable" {
  command = apply

  variables {
    monitoring_namespace = "observability"
  }

  assert {
    condition = (
      yamldecode(kubectl_manifest.monitoring_namespace[0].yaml_body).metadata.name == "observability" &&
      yamldecode(kubectl_manifest.victoria_metrics_k8s_stack[0].yaml_body).spec.destination.namespace == "observability" &&
      yamldecode(kubectl_manifest.grafana_gateway[0].yaml_body).metadata.namespace == "observability" &&
      yamldecode(kubectl_manifest.counter_api_dashboard[0].yaml_body).metadata.namespace == "observability"
    )
    error_message = "var.monitoring_namespace is not reaching everything that lives in it."
  }
}

################################################################################
# Dashboards
################################################################################

run "dashboard_is_labelled_for_the_grafana_sidecar" {
  command = apply

  # The sidecar picks ConfigMaps up by this label alone; without it the
  # dashboard exists and is simply never loaded.
  assert {
    condition     = yamldecode(kubectl_manifest.counter_api_dashboard[0].yaml_body).metadata.labels.grafana_dashboard == "1"
    error_message = "Without the grafana_dashboard label the sidecar never picks the ConfigMap up."
  }

  assert {
    condition     = can(jsondecode(yamldecode(kubectl_manifest.counter_api_dashboard[0].yaml_body).data["counter-api.json"]))
    error_message = "The dashboard ConfigMap does not contain valid JSON."
  }
}
