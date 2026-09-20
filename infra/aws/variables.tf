variable "region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "eu-west-1"
}
variable "environment" {
  description = "Environment name for testing"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "chamo"
}

variable "cluster_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnets" {
  description = "Private subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnets" {
  description = "Public subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "argocd_namespace" {
  type    = string
  default = "argocd"
}

variable "argocd_chart_version" {
  type    = string
  default = "10.9.1"
}

variable "additional_cluster_admin_arns" {
  description = <<-EOT
    IAM principal ARNs (users or roles) granted EKS cluster admin directly, in
    addition to the identity that runs `terraform apply`
    (enable_cluster_creator_admin_permissions already covers that one — e.g.
    the GitHub Actions IAM user).

    This is the escape hatch, not the front door. Humans belong in
    var.sso_access_permission_sets: an ARN listed here is a standing grant tied
    to a long-lived principal, invisible to Identity Center's own access
    reviews, and removing it takes a `terraform apply`. Use it for a machine
    principal that cannot go through Identity Center or the break-glass role.
  EOT
  type        = list(string)
  default     = []
}

variable "enable_argocd_route" {
  description = <<-EOT
    Expose the Argo CD UI through kgateway (Gateway API) instead of only via
    `kubectl port-forward`. When true, an HTTPRoute is created in the Argo CD
    namespace pointing at the `argocd-server` Service on plain HTTP port 80
    (03-argocd.tf runs the server with `server.insecure = true`, so TLS — if
    any — terminates at the Gateway/NLB, not at the pod).
  EOT
  type        = bool
  default     = true
}

variable "argocd_hostname" {
  description = <<-EOT
    Hostname the Argo CD HTTPRoute matches. kgateway routes on the Host header,
    so this must resolve to the Gateway's NLB address — a real DNS record, an
    /etc/hosts entry, or a wildcard-DNS name such as <nlb-ip>.sslip.io.

    Set it to "" to match ANY Host, which drops the DNS requirement entirely:
    the UI then answers on the Gateway's own NLB DNS name. Be deliberate about
    that on the shared Gateway (argocd_gateway_create = false) — a route with
    no hostname is the catch-all for every Host no other route claims, so the
    unencrypted Argo CD admin UI becomes the default backend of an
    internet-facing NLB. Pair it with argocd_gateway_create = true, or restrict
    the load balancer, before using it anywhere but a throwaway dev cluster.

    Only used when enable_argocd_route is true.
  EOT
  type        = string
  default     = "argocd.alvarolinarescabre.com"
}

variable "argocd_gateway_create" {
  description = <<-EOT
    How the Argo CD HTTPRoute gets its Gateway:
      false (default) - attach to an already existing Gateway
                        (var.argocd_gateway_name/_namespace, by default the
                        `public-nlb-gateway` the counter-api Helm chart
                        creates), reusing that Gateway's NLB. That Gateway
                        must allow routes from other namespaces
                        (`allowedRoutes.namespaces.from: All`, which the chart
                        sets).
      true            - create a dedicated Gateway + GatewayParameters in the
                        Argo CD namespace, which makes kgateway provision a
                        second, Argo-CD-only NLB (extra AWS cost, but keeps the
                        control plane off the application load balancer).
  EOT
  type        = bool
  default     = true
}

variable "argocd_gateway_name" {
  description = "Name of the Gateway to attach the Argo CD HTTPRoute to. Ignored when argocd_gateway_create is true (the dedicated Gateway is named `argocd-gateway`)."
  type        = string
  default     = "public-nlb-gateway"
}

variable "argocd_gateway_namespace" {
  description = "Namespace of the Gateway named in argocd_gateway_name. Ignored when argocd_gateway_create is true (the dedicated Gateway lives in var.argocd_namespace)."
  type        = string
  default     = "counter-api"
}

variable "argocd_gateway_section_name" {
  description = <<-EOT
    Listener (sectionName) on the target Gateway that the Argo CD HTTPRoute
    attaches to. When reusing a Gateway that already terminates TLS (the
    counter-api chart's, with gateway.https.enabled), point this at its TLS
    listener — "https" — so Argo CD is only reachable over the encrypted port.
  EOT
  type        = string
  default     = "http"
}

variable "argocd_gateway_https_section_name" {
  description = "Name of the TLS-fronted listener added to the dedicated Argo CD Gateway when argocd_gateway_tls_certificate_arn is set."
  type        = string
  default     = "https"
}

variable "argocd_gateway_tls_certificate_arn" {
  description = <<-EOT
    ARN of an ACM certificate for the dedicated Argo CD NLB. Setting it adds a
    second listener on port 443 to the Gateway and the aws-load-balancer-ssl-*
    annotations to its Service, so the NLB terminates TLS and forwards plain
    HTTP inwards — the listener protocol stays HTTP and no certificate ever
    enters the cluster. The certificate must be in var.region and cover
    var.argocd_hostname.

    Only used when argocd_gateway_create is true; a reused Gateway gets its TLS
    configuration from whoever owns it (for the counter-api chart's Gateway,
    that is gatewayParameters.tls.certificateArn in its values.yaml).
  EOT
  type        = string
  default     = ""
}

variable "argocd_gateway_tls_port" {
  description = "Frontend port the dedicated Argo CD NLB terminates TLS on."
  type        = number
  default     = 443
}

variable "argocd_gateway_tls_negotiation_policy" {
  description = "ELB security policy for the dedicated Argo CD NLB's TLS listener. Set to \"\" to leave it at the load balancer controller's default."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "argocd_gateway_class_name" {
  description = "GatewayClass used for the dedicated Argo CD Gateway. Only used when argocd_gateway_create is true."
  type        = string
  default     = "kgateway"
}

variable "argocd_gateway_annotations" {
  description = <<-EOT
    Annotations put on the Service that kgateway provisions for the dedicated
    Argo CD Gateway, via GatewayParameters. Defaults to the same internet-facing
    NLB configuration as deploy/argocd/kgateway/parameters.yaml. Only used when
    argocd_gateway_create is true.
  EOT
  type        = map(string)
  default = {
    "service.beta.kubernetes.io/aws-load-balancer-type"                                = "external"
    "service.beta.kubernetes.io/aws-load-balancer-scheme"                              = "internet-facing"
    "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"                     = "ip"
    "service.beta.kubernetes.io/aws-load-balancer-manage-backend-security-group-rules" = "true"
  }
}


variable "kgateway_sync_wait" {
  description = <<-EOT
    How long to wait after applying the kgateway Argo CD Applications before
    Terraform creates the first GatewayParameters.

    04-ingress-controller.tf only creates `Application` objects; Argo CD then
    has to pull the kgateway-crds and kgateway charts and sync them before
    gateway.kgateway.dev/v1alpha1 exists as an API. Applying a GatewayParameters
    any earlier fails with "isn't valid for cluster".

    This is a heuristic, not a check -- raise it if an apply on a cold cluster
    still fails that way.
  EOT
  type        = string
  default     = "120s"
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository holding the go-counter-href-10-sites image. Must match the repository part of image.repository in the Helm values and of ECR_REPOSITORY in the deploy workflow."
  type        = string
  default     = "go-counter-href-10-sites"
}

variable "ecr_untagged_expiry_days" {
  description = "Days before an untagged image in that repository is expired by the lifecycle policy."
  type        = number
  default     = 1
}

variable "ecr_keep_last_images" {
  description = <<-EOT
    How many `sha-` tagged images to keep. Older ones are expired by the
    lifecycle policy — keep this comfortably above the number of builds you
    might do between deployments, since expiring the image a running
    Deployment references would break any pod that has to be rescheduled.
  EOT
  type        = number
  default     = 20
}

################################################################################
# Managed node group (Karpenter's own footprint)
################################################################################

variable "node_group_instance_types" {
  description = <<-EOT
    Instance types for the EKS managed node group that hosts the cluster's
    "system" workloads -- CoreDNS, the Karpenter controller itself, Argo CD and
    kgateway. Karpenter cannot provision the node it runs on, so this group has
    to exist and stay up independently of it; everything else is expected to
    land on Karpenter-provisioned nodes.
  EOT
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_group_min_size" {
  description = "Minimum size of the managed node group."
  type        = number
  default     = 2
}

variable "node_group_max_size" {
  description = "Maximum size of the managed node group. Kept small on purpose -- growth beyond the system workloads is Karpenter's job, not this group's."
  type        = number
  default     = 3
}

variable "node_group_desired_size" {
  description = "Desired size of the managed node group."
  type        = number
  default     = 2
}

variable "node_group_disk_size" {
  description = "Root EBS volume size (GiB) for the managed node group's nodes."
  type        = number
  default     = 30
}

variable "node_group_capacity_type" {
  description = "Billing model for the managed node group: ON_DEMAND or SPOT. Keep it ON_DEMAND -- these nodes carry the controllers that would have to reschedule everything else."
  type        = string
  default     = "ON_DEMAND"
}

################################################################################
# Karpenter
################################################################################

variable "karpenter_chart_version" {
  description = "Version of the Karpenter Helm chart (oci://public.ecr.aws/karpenter/karpenter)."
  type        = string
  default     = "1.14.0"
}

variable "karpenter_namespace" {
  description = "Namespace the Karpenter controller runs in. kube-system is what the chart's IAM/pod-identity wiring in the terraform-aws-modules/eks karpenter submodule defaults to."
  type        = string
  default     = "kube-system"
}

variable "karpenter_node_instance_categories" {
  description = "Instance categories Karpenter may pick from for the nodes it provisions. No \"t\": burstable instances run out of CPU credits under sustained load and add latency spikes."
  type        = list(string)
  default     = ["c", "m", "r"]
}

variable "karpenter_node_instance_generations_min" {
  description = "Minimum instance generation Karpenter may pick (excludes old, slow, comparatively expensive families)."
  type        = number
  default     = 3
}

variable "karpenter_node_architectures" {
  description = "CPU architectures Karpenter may provision. Only amd64 by default because the counter-api image is built for linux/amd64 alone; add \"arm64\" (Graviton, usually cheaper) once CI publishes a multi-arch image."
  type        = list(string)
  default     = ["amd64"]
}

variable "karpenter_node_capacity_types" {
  description = "Capacity types Karpenter may provision. With both listed it prefers spot and falls back to on-demand when no spot capacity is available."
  type        = list(string)
  default     = ["spot", "on-demand"]
}

variable "karpenter_node_cpu_limit" {
  description = <<-EOT
    Ceiling on the total vCPU Karpenter may have running across all the nodes
    of its NodePool. This is the cost guardrail: without it a runaway
    ReplicaSet can scale the AWS bill, not just the cluster.
  EOT
  type        = number
  default     = 32
}

variable "karpenter_node_expire_after" {
  description = "How long a Karpenter-provisioned node lives before it is drained and replaced, which is how nodes pick up new AMIs. Set to \"Never\" to disable."
  type        = string
  default     = "720h"
}

variable "karpenter_node_consolidation_after" {
  description = "How long a node must sit underutilised/empty before Karpenter consolidates it away."
  type        = string
  default     = "1m"
}

variable "karpenter_node_ami_alias" {
  description = "AMI family/version alias Karpenter resolves nodes from. \"@latest\" tracks new AMI releases; pin a version (e.g. al2023@v20250101) for reproducible node images."
  type        = string
  default     = "al2023@latest"
}

################################################################################
# AWS Load Balancer Controller
################################################################################

variable "load_balancer_controller_chart_version" {
  description = "Version of the aws-load-balancer-controller Helm chart. Must be >= 3.0 for the EKS Pod Identity credential path used in 09-load-balancer-controller.tf; older charts need IRSA instead."
  type        = string
  default     = "3.5.0"
}

variable "load_balancer_controller_namespace" {
  description = "Namespace the AWS Load Balancer Controller runs in."
  type        = string
  default     = "kube-system"
}

variable "load_balancer_teardown_wait" {
  description = <<-EOT
    How long `terraform destroy` holds the AWS Load Balancer Controller (and so
    the cluster) alive after the last Gateway is deleted, so the controller can
    finish deleting the NLBs it created.

    Nothing in Terraform owns those NLBs, and deleting a Gateway returns long
    before the NLB behind it is gone -- see time_sleep.load_balancer_teardown in
    09-load-balancer-controller.tf. An NLB delete usually takes 30-60s; the
    default leaves margin for three of them (counter-api, Argo CD, Grafana).

    It costs nothing on apply. Raise it if a destroy still leaves load balancers
    behind; lower it only if you are certain no Gateway is left.
  EOT
  type        = string
  default     = "180s"
}

variable "load_balancer_controller_service_account" {
  description = "Service account name for the AWS Load Balancer Controller. The Pod Identity association is bound to this exact name, so the chart must be told to use it too."
  type        = string
  default     = "aws-load-balancer-controller"
}

################################################################################
# Human cluster access (10-cluster-access.tf)
################################################################################

variable "sso_access_permission_sets" {
  description = <<-EOT
    IAM Identity Center permission sets that get access to the cluster, keyed by
    the permission set's exact name (case sensitive -- it is matched against the
    `AWSReservedSSO_<name>_<hash>` role Identity Center provisions in this
    account).

    Terraform does not create these permission sets, and does not assign them:
    do that where Identity Center is administered, assign them to THIS account,
    and then apply. A permission set that has never been assigned here has no
    role to point an access entry at, and the apply fails saying so.

      access_policy  Which AWS-managed EKS access policy the permission set
                     gets: "cluster-admin" (full admin, cluster scope only),
                     "admin", "admin-view", "edit" or "view".
      namespaces     Restrict the grant to these namespaces. null (the default)
                     means cluster-wide. Not valid with "cluster-admin", which
                     AWS only allows at cluster scope.

    An empty map means nobody reaches the cluster through Identity Center.
  EOT

  type = map(object({
    access_policy = optional(string, "view")
    namespaces    = optional(list(string))
  }))

  default = {
    EKSClusterAdmin = {
      access_policy = "cluster-admin"
    }
    EKSViewer = {
      access_policy = "view"
    }
  }

  validation {
    condition = alltrue([
      for k, v in var.sso_access_permission_sets :
      contains(["cluster-admin", "admin", "admin-view", "edit", "view"], v.access_policy)
    ])
    error_message = "access_policy must be one of: cluster-admin, admin, admin-view, edit, view."
  }

  validation {
    condition = alltrue([
      for k, v in var.sso_access_permission_sets :
      v.namespaces == null || v.access_policy != "cluster-admin"
    ])
    error_message = "access_policy \"cluster-admin\" cannot be namespace-scoped; use \"admin\" with namespaces instead."
  }
}

variable "break_glass_role_enabled" {
  description = <<-EOT
    Create the emergency cluster-admin role. Its point is to be independent of
    Identity Center, so that an outage of the identity store or the access
    portal does not also lock everyone out of the cluster. Turn it off only if
    you have another Identity-Center-independent way in -- with it off and
    var.additional_cluster_admin_arns empty, the only remaining admin is
    whichever principal ran `terraform apply`.
  EOT
  type        = bool
  default     = true
}

variable "break_glass_trusted_principals" {
  description = <<-EOT
    IAM ARNs allowed to assume the break-glass role. Empty (the default) means
    the account root ARN, which delegates the decision to the account's own IAM:
    a principal can assume it only if an identity policy also allows it, which
    is what the `<project>-<env>-eks-break-glass-assume` managed policy grants
    to whoever you attach it to. Narrow this to specific ARNs if you would
    rather the trust policy itself be the allow-list.
  EOT
  type        = list(string)
  default     = []
}

variable "break_glass_require_mfa" {
  description = "Require the caller's session to carry MFA before it may assume the break-glass role."
  type        = bool
  default     = true
}

variable "break_glass_max_session_duration" {
  description = "Seconds before an assumed break-glass session expires. Kept at the one-hour minimum on purpose: an emergency session should not outlive the emergency."
  type        = number
  default     = 3600

  validation {
    condition     = var.break_glass_max_session_duration >= 3600 && var.break_glass_max_session_duration <= 43200
    error_message = "max_session_duration must be between 3600 and 43200 seconds (AWS limits)."
  }
}

variable "enable_monitoring" {
  description = "Install VictoriaMetrics (victoria-metrics-k8s-stack) and Grafana through Argo CD."
  type        = bool
  default     = true
}

variable "monitoring_namespace" {
  description = "Namespace for VictoriaMetrics, Grafana and their exporters."
  type        = string
  default     = "monitoring"
}

variable "victoria_metrics_k8s_stack_chart_version" {
  description = "Version of the victoria-metrics-k8s-stack Helm chart."
  type        = string
  default     = "0.92.1"
}

variable "monitoring_retention" {
  description = "How long VMSingle keeps samples. Units: h, d, w, y; a bare number means months."
  type        = string
  default     = "15d"
}

variable "monitoring_storage_size" {
  description = "Size of the gp3 volume VMSingle stores its data on."
  type        = string
  default     = "20Gi"
}

variable "enable_grafana_route" {
  description = "Publish Grafana through a dedicated kgateway Gateway (its own internet-facing NLB, plain HTTP). When false, reach it with kubectl port-forward."
  type        = bool
  default     = true
}

variable "grafana_hostname" {
  description = "Hostname the Grafana HTTPRoute matches. Point a DNS record at the Grafana Gateway's NLB. Empty matches any Host header."
  type        = string
  default     = "grafana.alvarolinarescabre.com"
}
