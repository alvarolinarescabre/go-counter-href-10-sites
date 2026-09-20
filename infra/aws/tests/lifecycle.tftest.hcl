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
# Lifecycle: the orderings that only fail against a real cluster.
#
# Two halves, and they are mirror images. Bringing the stack up, several
# resources must not be created until something else is actually ready; tearing
# it down, several must not be deleted until something else is still alive.
# Neither dependency is expressible as an attribute reference, so both are
# carried by depends_on chains and by the configuration asserted below.
#
# ---------------------------------------------------------------- Destroy
#
# Every NLB in this stack is created by the AWS Load Balancer Controller from
# inside the cluster, in response to a Service kgateway provisions for a
# Gateway. Terraform owns none of them, so a clean `terraform destroy` depends
# on two things it CAN control:
#
#   1. that deleting an Argo CD Application actually cascades to the resources
#      it deployed (otherwise the Gateway, the Service and the NLB simply
#      survive), and
#   2. that the load balancer controller outlives those deletions long enough
#      to finish deleting the NLBs.
#
# Neither is observable from a plan, and `terraform test` cannot assert on
# destroy ordering. What it CAN pin is the configuration both rely on -- which
# is exactly what silently regresses. The ordering itself is enforced by the
# depends_on chain through time_sleep.load_balancer_teardown.
################################################################################

run "argo_cd_applications_cascade_on_delete" {
  command = apply

  # Without the finalizer, deleting this Application removes only the
  # Application CR. The counter-api namespace, the Gateway and the kgateway
  # LoadBalancer Service all survive, nothing asks the controller to delete the
  # NLB, and the VPC destroy later fails with DependencyViolation because the
  # orphaned NLB's ENIs still hold the private subnets.
  assert {
    condition = contains(
      yamldecode(kubectl_manifest.argocd_application.yaml_body).metadata.finalizers,
      "resources-finalizer.argocd.argoproj.io"
    )
    error_message = "deploy/argocd/application.yaml lost its cascade finalizer: terraform destroy would leave the counter-api NLB behind."
  }

  # Same for the monitoring stack, where the cascade also has to reach the
  # VMSingle and Grafana PVCs -- and therefore the gp3 EBS volumes behind them,
  # which otherwise outlive the cluster and keep being billed.
  assert {
    condition = contains(
      yamldecode(kubectl_manifest.victoria_metrics_k8s_stack[0].yaml_body).metadata.finalizers,
      "resources-finalizer.argocd.argoproj.io"
    )
    error_message = "The victoria-metrics-k8s-stack Application lost its cascade finalizer: its namespace, PVCs and EBS volumes would survive the destroy."
  }
}

# The EC2 instances Karpenter launches belong to no Terraform resource and to no
# Auto Scaling group. The only thing that terminates them is Karpenter itself,
# draining the NodeClaims that own them -- which only happens if the NodePool
# delete blocks long enough for it.
run "node_pool_deletion_waits_for_the_instances" {
  command = apply

  assert {
    condition     = kubectl_manifest.karpenter_node_pool.wait == true
    error_message = "Without wait = true the NodePool delete returns immediately, Terraform removes the Karpenter controller and the cluster mid-drain, and every Karpenter-launched EC2 instance is orphaned -- taking the VPC destroy down with it."
  }

  # Foreground is what makes the NodePool outlive its NodeClaims, and a
  # NodeClaim only goes once its instance is terminated.
  assert {
    condition     = kubectl_manifest.karpenter_node_pool.delete_cascade == "Foreground"
    error_message = "A Background cascade lets the NodePool disappear while its NodeClaims are still draining, which defeats wait = true."
  }
}

# A PodDisruptionBudget cannot block the eviction of a pod that no longer
# exists. Both Argo CD Applications are ordered ahead of the NodePool so the
# workloads carrying PDBs are gone before the drain starts.
run "workloads_are_removed_before_the_drain" {
  command = apply

  assert {
    condition     = var.enable_monitoring == true
    error_message = "This run assumes the monitoring stack is on; both Applications are ordered against the NodePool."
  }

  # The chart's own PDBs are the reason the ordering matters -- if they ever
  # went away this test's rationale would need revisiting, not the ordering.
  assert {
    condition     = yamldecode(kubectl_manifest.argocd_application.yaml_body).spec.destination.namespace == "counter-api"
    error_message = "The counter-api Application no longer targets the namespace whose PodDisruptionBudget the drain has to get past."
  }
}

# The same deterministic trick as the NodePool, applied to the NLBs: kgateway
# owns each Gateway's Service, and that Service's finalizer is only cleared once
# the load balancer controller has deleted the NLB.
run "gateway_deletion_waits_for_the_load_balancer" {
  command = apply

  assert {
    condition     = kubectl_manifest.argocd_gateway[0].wait == true && kubectl_manifest.argocd_gateway[0].delete_cascade == "Foreground"
    error_message = "The Argo CD Gateway no longer blocks on its Service being deleted, so Terraform can move on while the NLB is still there."
  }

  assert {
    condition     = kubectl_manifest.grafana_gateway[0].wait == true && kubectl_manifest.grafana_gateway[0].delete_cascade == "Foreground"
    error_message = "The Grafana Gateway no longer blocks on its Service being deleted."
  }

  # The third NLB is counter-api's, and Terraform owns neither its Gateway nor
  # its Service -- the chart creates them. What it can block on is the Argo CD
  # Application: the resources-finalizer asserted above keeps the object in
  # Terminating until Argo CD has pruned the Gateway, and `wait` blocks on that
  # finalizer. Without it the delete returns mid-cascade and only
  # time_sleep.load_balancer_teardown's timer stands between a slow NLB delete
  # and an orphaned load balancer.
  assert {
    condition     = kubectl_manifest.argocd_application.wait == true
    error_message = "The counter-api Application no longer waits for its Argo CD finalizer, so its NLB is back to being a race against the teardown timer."
  }

  assert {
    condition     = kubectl_manifest.argocd_application.delete_cascade == "Foreground"
    error_message = "A Background cascade defeats wait = true on the Application."
  }
}

# The EBS volumes behind the VMSingle and Grafana PVCs belong to no Terraform
# resource: the CSI driver creates them, and only the CSI driver deletes them.
# Two destroys leaked them (a 20Gi and a 5Gi left `available`) because nothing
# here blocked on the deletion actually happening.
run "pvc_deletion_is_waited_for_before_the_csi_driver_goes" {
  command = apply

  assert {
    condition     = kubectl_manifest.monitoring_namespace[0].wait == true
    error_message = "Without wait, Terraform fires the namespace DELETE and moves on while the PVCs -- and so the EBS volumes -- are still being removed."
  }

  assert {
    condition     = kubectl_manifest.victoria_metrics_k8s_stack[0].wait == true && kubectl_manifest.victoria_metrics_k8s_stack[0].delete_cascade == "Foreground"
    error_message = "The monitoring Application no longer blocks on its Argo CD finalizer, so the chart's prune (Grafana's PVC included) races the namespace delete."
  }

  # The volume delete lands on the PV a moment after the PVC is gone, and the
  # CSI driver is an addon inside module.eks. The barrier is that moment.
  assert {
    condition     = time_sleep.storage_teardown.destroy_duration == "60s"
    error_message = "The storage teardown barrier is not var.storage_teardown_wait."
  }

  assert {
    condition     = time_sleep.storage_teardown.create_duration == null
    error_message = "The storage barrier must cost nothing on apply -- it is a destroy-only delay."
  }
}

run "the_storage_teardown_wait_is_tunable" {
  command = apply

  variables {
    storage_teardown_wait = "120s"
  }

  assert {
    condition     = time_sleep.storage_teardown.destroy_duration == "120s"
    error_message = "var.storage_teardown_wait is not reaching the barrier."
  }
}

run "the_teardown_barrier_costs_nothing_on_apply" {
  command = apply

  # A create_duration here would add dead time to every single apply. The
  # barrier exists purely to slow the destroy down.
  assert {
    condition     = time_sleep.load_balancer_teardown.create_duration == null
    error_message = "The teardown barrier must not delay apply; it only has a job on destroy."
  }

  assert {
    condition     = time_sleep.load_balancer_teardown.destroy_duration == "180s"
    error_message = "The teardown barrier is not var.load_balancer_teardown_wait."
  }
}

run "the_teardown_wait_is_tunable" {
  command = apply

  variables {
    load_balancer_teardown_wait = "300s"
  }

  assert {
    condition     = time_sleep.load_balancer_teardown.destroy_duration == "300s"
    error_message = "var.load_balancer_teardown_wait is not reaching the barrier."
  }
}

# The barrier only helps if the controller is actually still installed when the
# Gateways are deleted, which is what the depends_on chain guarantees. The
# chart being present at all is the precondition for any of it.
run "the_controller_that_deletes_the_nlbs_is_installed" {
  command = apply

  assert {
    condition     = helm_release.aws_load_balancer_controller.name == "aws-load-balancer-controller"
    error_message = "Nothing in this stack deletes an NLB except this controller; without it the Gateways come up with no address and go down leaving the load balancers behind."
  }
}

# kgateway must NOT cascade: it has to stay up while the Gateways above are
# being deleted, because it is what turns a Gateway deletion into a Service
# deletion. Its own resources die with the cluster anyway.
run "kgateway_deliberately_does_not_cascade" {
  command = apply

  assert {
    condition     = !can(yamldecode(kubectl_manifest.kgateway_helm.yaml_body).metadata.finalizers)
    error_message = "The kgateway Application must not carry a cascade finalizer: deleting it would tear kgateway down before the Gateways that depend on it are cleaned up."
  }
}

################################################################################
# Bring-up ordering
#
# The mirror image of the teardown problem above: on a cold cluster, several
# things have to exist before Terraform may create the next one, and neither
# dependency is expressible as an attribute reference. Ordering itself is not
# assertable from a test -- what is assertable is the configuration the ordering
# is built from, which is what quietly regresses.
################################################################################

run "service_mutator_webhook_stays_off" {
  command = apply

  # The chart registers this webhook with failurePolicy: Fail and no selector,
  # so it intercepts EVERY Service creation in the cluster. With it on, any
  # window where the controller has no ready endpoints -- a rollout, a node
  # replacement, a Karpenter consolidation -- blocks Service creation
  # everywhere, which is what breaks the Karpenter install on a cold cluster.
  #
  # It is safe to leave off only because every NLB Service here is created from
  # GatewayParameters that already carry aws-load-balancer-type: external. If
  # that ever stops being true, this has to be reconsidered, not just flipped.
  assert {
    condition     = yamldecode(helm_release.aws_load_balancer_controller.values[0]).enableServiceMutatorWebhook == false
    error_message = "The service mutator webhook is on again: it intercepts every Service in the cluster with failurePolicy Fail, and the controller having no endpoints then blocks Karpenter, kgateway and Grafana from creating theirs."
  }

  # The reason the mutation is redundant: the annotation already says who owns
  # the load balancer.
  assert {
    condition     = var.argocd_gateway_annotations["service.beta.kubernetes.io/aws-load-balancer-type"] == "external"
    error_message = "Without aws-load-balancer-type: external the Services DO need the mutator webhook to be picked up by the controller -- turning it off would leave them unmanaged."
  }
}

run "kgateway_crds_are_waited_for_before_gateway_parameters" {
  command = apply

  # 04-ingress-controller.tf only creates Argo CD Application objects; Argo CD
  # still has to pull and sync the charts before gateway.kgateway.dev/v1alpha1
  # exists. A GatewayParameters applied before that fails with "isn't valid for
  # cluster".
  assert {
    condition     = time_sleep.wait_for_kgateway_crds.create_duration == "120s"
    error_message = "The wait for Argo CD to sync kgateway is not var.kgateway_sync_wait."
  }

  assert {
    condition     = time_sleep.wait_for_kgateway_crds.create_duration != null
    error_message = "Without a create_duration this sleep is a no-op and the GatewayParameters race is back."
  }
}

run "the_kgateway_wait_is_tunable" {
  command = apply

  variables {
    kgateway_sync_wait = "300s"
  }

  assert {
    condition     = time_sleep.wait_for_kgateway_crds.create_duration == "300s"
    error_message = "var.kgateway_sync_wait is not reaching the sleep."
  }
}
