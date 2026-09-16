terraform {
  required_version = ">= 1.10"

  # Local state, deliberately. This root manages the two IAM users whose access
  # keys the main stack authenticates with, so it cannot depend on anything
  # those users provide -- including the S3 backend they are granted access to.
  # It runs rarely, by a human with administrator credentials, and its state
  # holds nothing the account itself is not already the source of truth for.
  #
  # `terraform.tfstate` here is covered by the repo's *.tfstate ignore. Keep it:
  # losing it does not lose the users, but re-adopting them then needs the
  # `terraform import` commands in this directory's README.

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Owner       = "Chamo"
      ManagedBy   = "Terraform"
      Terraform   = "infra/aws/bootstrap"
      Environment = "Dev"
    }
  }
}
