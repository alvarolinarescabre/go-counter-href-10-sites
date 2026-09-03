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
  default     = "1.35"
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
  default = "7.8.2"
}

variable "additional_cluster_admin_arns" {
  description = <<-EOT
    IAM principal ARNs (users or roles) to grant EKS cluster admin access to,
    in addition to the identity that runs `terraform apply`
    (enable_cluster_creator_admin_permissions already covers that one — e.g.
    the GitHub Actions IAM user). Add your own local IAM user/role ARN here
    (`aws sts get-caller-identity --query Arn --output text`) to be able to
    run kubectl against the cluster from your machine.
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
  default     = "arn:aws:acm:eu-west-1:133630512259:certificate/c0116ba9-38d4-4147-a445-b3837a83f88d"
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


variable "ecr_repository_name" {
  description = "Name of the ECR repository holding the counter-api image. Must match the repository part of image.repository in the Helm values and of ECR_REPOSITORY in the deploy workflow."
  type        = string
  default     = "counter-api"
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
