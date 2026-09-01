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