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
# 06-argocd-ingress.tf and the locals behind it.
#
# The densest conditional logic in the stack: whether a Gateway is created or
# reused, whether TLS terminates at the NLB, which listeners the HTTPRoute
# attaches to, and whether the route matches a Host at all. Every manifest is
# built with yamlencode(), so the tests read the rendered YAML back.
################################################################################

################################################################################
# Defaults: a dedicated Gateway, plain HTTP
################################################################################

run "dedicated_gateway_by_default" {
  command = apply

  assert {
    condition     = local.argocd_gateway_name == "argocd-gateway" && local.argocd_gateway_namespace == "argocd"
    error_message = "With argocd_gateway_create = true the Gateway is always named argocd-gateway and lives in the Argo CD namespace."
  }

  assert {
    condition     = length(kubectl_manifest.argocd_gateway) == 1 && length(kubectl_manifest.argocd_gateway_parameters) == 1
    error_message = "A dedicated Gateway needs both the Gateway and its GatewayParameters."
  }

  # parametersRef is a local reference (group/kind/name, no namespace), so the
  # GatewayParameters must be in the Gateway's own namespace.
  assert {
    condition     = yamldecode(kubectl_manifest.argocd_gateway_parameters[0].yaml_body).metadata.namespace == yamldecode(kubectl_manifest.argocd_gateway[0].yaml_body).metadata.namespace
    error_message = "GatewayParameters must live in the same namespace as the Gateway that references it; parametersRef carries no namespace."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.argocd_gateway[0].yaml_body).spec.infrastructure.parametersRef.name == local.argocd_gateway_params
    error_message = "The Gateway does not reference the GatewayParameters this file creates."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.argocd_gateway[0].yaml_body).spec.gatewayClassName == "kgateway"
    error_message = "The Gateway is not on the kgateway GatewayClass."
  }
}

run "plain_http_gateway_has_one_listener" {
  command = apply

  assert {
    condition     = length(yamldecode(kubectl_manifest.argocd_gateway[0].yaml_body).spec.listeners) == 1
    error_message = "Without a TLS certificate the Gateway should have exactly the one HTTP listener."
  }

  assert {
    condition = (
      yamldecode(kubectl_manifest.argocd_gateway[0].yaml_body).spec.listeners[0].name == "http" &&
      yamldecode(kubectl_manifest.argocd_gateway[0].yaml_body).spec.listeners[0].port == 80 &&
      yamldecode(kubectl_manifest.argocd_gateway[0].yaml_body).spec.listeners[0].protocol == "HTTP"
    )
    error_message = "The default listener should be HTTP on port 80."
  }

  # The Gateway is dedicated to Argo CD; nothing in another namespace should be
  # able to attach a route to it.
  assert {
    condition     = yamldecode(kubectl_manifest.argocd_gateway[0].yaml_body).spec.listeners[0].allowedRoutes.namespaces.from == "Same"
    error_message = "The dedicated Argo CD Gateway must only accept routes from its own namespace."
  }

  assert {
    condition     = local.argocd_url_scheme == "http"
    error_message = "With no TLS certificate and the http listener, the UI is reached over http."
  }

  assert {
    condition     = local.argocd_gateway_tls == false
    error_message = "local.argocd_gateway_tls must be false when no certificate ARN is set."
  }
}

run "route_points_at_the_dedicated_gateway" {
  command = apply

  assert {
    condition     = length(kubectl_manifest.argocd_httproute) == 1
    error_message = "enable_argocd_route defaults to true, so the HTTPRoute should exist."
  }

  assert {
    condition     = tolist(local.argocd_route_section_names) == tolist(["http"])
    error_message = "With no TLS the route attaches to the http listener only."
  }

  assert {
    condition = (
      length(yamldecode(kubectl_manifest.argocd_httproute[0].yaml_body).spec.parentRefs) == 1 &&
      yamldecode(kubectl_manifest.argocd_httproute[0].yaml_body).spec.parentRefs[0].name == "argocd-gateway" &&
      yamldecode(kubectl_manifest.argocd_httproute[0].yaml_body).spec.parentRefs[0].namespace == "argocd" &&
      yamldecode(kubectl_manifest.argocd_httproute[0].yaml_body).spec.parentRefs[0].sectionName == "http"
    )
    error_message = "The HTTPRoute's parentRef does not name the dedicated Gateway's http listener."
  }

  assert {
    condition     = tolist(yamldecode(kubectl_manifest.argocd_httproute[0].yaml_body).spec.hostnames) == tolist(["argocd.alvarolinarescabre.com"])
    error_message = "The route should match var.argocd_hostname."
  }

  # 03-argocd.tf runs the server with server.insecure = true, so the backend is
  # plain HTTP on port 80 and TLS, if any, stops at the NLB.
  assert {
    condition = (
      yamldecode(kubectl_manifest.argocd_httproute[0].yaml_body).spec.rules[0].backendRefs[0].name == "argocd-server" &&
      yamldecode(kubectl_manifest.argocd_httproute[0].yaml_body).spec.rules[0].backendRefs[0].port == 80
    )
    error_message = "The route must forward to argocd-server:80 -- the server runs insecure, so there is no 443 to talk to."
  }

  assert {
    condition     = yamldecode(helm_release.argocd.values[0]).configs.params["server.insecure"] == true
    error_message = "The Argo CD server is no longer running insecure, but the route still targets its plain HTTP port."
  }
}

################################################################################
# TLS at the NLB
################################################################################

run "tls_certificate_adds_a_second_listener_and_the_ssl_annotations" {
  command = apply

  variables {
    argocd_gateway_tls_certificate_arn = "arn:aws:acm:eu-west-1:111122223333:certificate/abcd-1234"
  }

  assert {
    condition     = local.argocd_gateway_tls == true
    error_message = "A certificate ARN on a self-created Gateway must switch TLS on."
  }

  assert {
    condition     = length(yamldecode(kubectl_manifest.argocd_gateway[0].yaml_body).spec.listeners) == 2
    error_message = "A certificate should add a second listener to the Gateway."
  }

  # The trick this config relies on: the NLB terminates TLS with the ACM
  # certificate and forwards plain HTTP inwards, so the second listener's
  # protocol is HTTP and no certificate ever enters the cluster.
  assert {
    condition = (
      yamldecode(kubectl_manifest.argocd_gateway[0].yaml_body).spec.listeners[1].name == "https" &&
      yamldecode(kubectl_manifest.argocd_gateway[0].yaml_body).spec.listeners[1].port == 443 &&
      yamldecode(kubectl_manifest.argocd_gateway[0].yaml_body).spec.listeners[1].protocol == "HTTP"
    )
    error_message = "The TLS-fronted listener must stay protocol HTTP on the TLS port: the NLB does the handshake, the Gateway never sees one."
  }

  assert {
    condition     = !can(yamldecode(kubectl_manifest.argocd_gateway[0].yaml_body).spec.listeners[1].tls)
    error_message = "The TLS-fronted listener must carry no tls block; there is no certificate inside the cluster to serve."
  }

  assert {
    condition = (
      local.argocd_gateway_service_annotations["service.beta.kubernetes.io/aws-load-balancer-ssl-cert"] == "arn:aws:acm:eu-west-1:111122223333:certificate/abcd-1234" &&
      local.argocd_gateway_service_annotations["service.beta.kubernetes.io/aws-load-balancer-ssl-ports"] == "443" &&
      local.argocd_gateway_service_annotations["service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy"] == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    )
    error_message = "The ssl-* annotations that make the NLB terminate TLS are missing or wrong."
  }

  # The base annotations must survive the merge, or the Service stops being an
  # internet-facing IP-target NLB.
  assert {
    condition     = local.argocd_gateway_service_annotations["service.beta.kubernetes.io/aws-load-balancer-scheme"] == "internet-facing"
    error_message = "Adding the TLS annotations dropped the base NLB annotations."
  }

  assert {
    condition     = tolist(local.argocd_route_section_names) == tolist(["http", "https"])
    error_message = "With TLS on, the route should attach to both listeners."
  }

  assert {
    condition     = length(yamldecode(kubectl_manifest.argocd_httproute[0].yaml_body).spec.parentRefs) == 2
    error_message = "The HTTPRoute should have a parentRef per listener."
  }

  assert {
    condition     = local.argocd_url_scheme == "https"
    error_message = "With TLS terminating at the NLB, the UI URL is https."
  }
}

run "tls_port_and_negotiation_policy_are_configurable" {
  command = apply

  variables {
    argocd_gateway_tls_certificate_arn    = "arn:aws:acm:eu-west-1:111122223333:certificate/abcd-1234"
    argocd_gateway_tls_port               = 8443
    argocd_gateway_tls_negotiation_policy = ""
  }

  assert {
    condition     = yamldecode(kubectl_manifest.argocd_gateway[0].yaml_body).spec.listeners[1].port == 8443
    error_message = "var.argocd_gateway_tls_port is not reaching the listener."
  }

  assert {
    condition     = local.argocd_gateway_service_annotations["service.beta.kubernetes.io/aws-load-balancer-ssl-ports"] == "8443"
    error_message = "The ssl-ports annotation must follow the TLS port, or the NLB terminates TLS on a port nothing listens on."
  }

  # An empty policy means "leave it at the controller's default", which has to
  # be the annotation being absent -- not present and empty.
  assert {
    condition     = !contains(keys(local.argocd_gateway_service_annotations), "service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy")
    error_message = "An empty negotiation policy must omit the annotation entirely rather than set it to \"\"."
  }
}

################################################################################
# Reusing someone else's Gateway
################################################################################

run "reused_gateway_creates_nothing_and_points_elsewhere" {
  command = apply

  variables {
    argocd_gateway_create = false
  }

  assert {
    condition     = length(kubectl_manifest.argocd_gateway) == 0 && length(kubectl_manifest.argocd_gateway_parameters) == 0
    error_message = "Reusing a Gateway must not provision a second NLB."
  }

  assert {
    condition     = local.argocd_gateway_name == "public-nlb-gateway" && local.argocd_gateway_namespace == "counter-api"
    error_message = "With argocd_gateway_create = false the route should target the Gateway named by the variables -- by default the one the counter-api chart creates."
  }

  assert {
    condition = (
      yamldecode(kubectl_manifest.argocd_httproute[0].yaml_body).spec.parentRefs[0].name == "public-nlb-gateway" &&
      yamldecode(kubectl_manifest.argocd_httproute[0].yaml_body).spec.parentRefs[0].namespace == "counter-api"
    )
    error_message = "The HTTPRoute is not attached to the reused Gateway."
  }
}

# TLS configuration only applies to a Gateway we own; a reused one is configured
# by whoever owns it.
run "tls_certificate_is_ignored_on_a_reused_gateway" {
  command = apply

  variables {
    argocd_gateway_create              = false
    argocd_gateway_tls_certificate_arn = "arn:aws:acm:eu-west-1:111122223333:certificate/abcd-1234"
  }

  assert {
    condition     = local.argocd_gateway_tls == false
    error_message = "A certificate ARN must not switch TLS on for a Gateway this config does not own -- there is nothing here to attach it to."
  }

  assert {
    condition     = tolist(local.argocd_route_section_names) == tolist(["http"])
    error_message = "The route should still attach to the single configured listener on a reused Gateway."
  }
}

# When the reused Gateway already terminates TLS, pointing the route at its
# `https` listener is what keeps Argo CD off the plaintext port.
run "reused_https_listener_reports_an_https_url" {
  command = apply

  variables {
    argocd_gateway_create       = false
    argocd_gateway_section_name = "https"
  }

  assert {
    condition     = local.argocd_url_scheme == "https"
    error_message = "Attaching to a TLS listener should make the reported URL https."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.argocd_httproute[0].yaml_body).spec.parentRefs[0].sectionName == "https"
    error_message = "var.argocd_gateway_section_name is not reaching the parentRef."
  }
}

################################################################################
# Host matching and the off switch
################################################################################

# An empty hostname matches ANY Host, so the UI answers on the NLB's own DNS
# name and no domain is needed. On a shared Gateway that also makes the
# unencrypted admin UI the catch-all backend -- hence the warning in the
# variable, and hence this being explicit rather than incidental.
run "empty_hostname_matches_any_host" {
  command = apply

  variables {
    argocd_hostname = ""
  }

  assert {
    condition     = length(yamldecode(kubectl_manifest.argocd_httproute[0].yaml_body).spec.hostnames) == 0
    error_message = "An empty argocd_hostname must produce no hostnames at all, which is how Gateway API spells \"any Host\"."
  }
}

run "route_can_be_turned_off_entirely" {
  command = apply

  variables {
    enable_argocd_route = false
  }

  assert {
    condition     = length(kubectl_manifest.argocd_httproute) == 0
    error_message = "enable_argocd_route = false must create no HTTPRoute."
  }

  # No route means the Gateway would have nothing attached to it, so it is not
  # provisioned either -- an NLB with no backend is pure cost.
  assert {
    condition     = length(kubectl_manifest.argocd_gateway) == 0 && length(kubectl_manifest.argocd_gateway_parameters) == 0
    error_message = "With the route off, the dedicated Gateway (and its NLB) must not be created."
  }

  assert {
    condition     = strcontains(local.argocd_login_instructions, "port-forward")
    error_message = "With no route, the instructions output should fall back to kubectl port-forward."
  }
}
