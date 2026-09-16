variable "region" {
  description = "AWS region. Only used to address the provider -- IAM itself is global."
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Project name prefix. Must match var.project_name in the main stack: the apply policy scopes its IAM grants to resources named `<project_name>-<environment>-*`."
  type        = string
  default     = "chamo"
}

variable "environment" {
  description = "Environment name. Must match var.environment in the main stack, for the same reason as project_name."
  type        = string
  default     = "dev"
}

variable "state_bucket" {
  description = "Terraform state bucket the CI users are granted access to. Must match the `backend \"s3\"` block in ../providers.tf."
  type        = string
  default     = "chamo-terraform-state-2027"
}

variable "plan_user_name" {
  description = "IAM user for the automatic, read-only `plan-on-main` job. Defaults to the name the setup docs used, so an existing user can be adopted with `terraform import` rather than recreated."
  type        = string
  default     = "gha-counter-api-terraform-plan"
}

variable "apply_user_name" {
  description = "IAM user for the manual, reviewer-gated apply/destroy job."
  type        = string
  default     = "gha-counter-api-terraform-apply"
}

variable "create_access_keys" {
  description = <<-EOT
    Also create an access key for each user. Off by default because the secret
    is then stored in this root's state file in plain text -- and this root
    keeps state locally, so that file is on whoever's laptop ran it.

    Turning it on is reasonable for a one-shot bootstrap where you immediately
    copy the values into GitHub secrets. `terraform output -json ci_access_keys`
    prints them; treat the state file as a credential afterwards, or run
    `terraform state rm` on the keys once GitHub has them.
  EOT
  type        = bool
  default     = false
}
