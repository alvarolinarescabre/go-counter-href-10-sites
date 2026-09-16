output "ci_users" {
  description = "The two IAM users the GitHub Actions workflow authenticates as, and the policies attached to each."
  value = {
    plan = {
      name = aws_iam_user.ci["plan"].name
      arn  = aws_iam_user.ci["plan"].arn
      policies = [
        "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess",
        aws_iam_policy.terraform_shared.arn,
      ]
    }
    apply = {
      name = aws_iam_user.ci["apply"].name
      arn  = aws_iam_user.ci["apply"].arn
      policies = [
        "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess",
        aws_iam_policy.terraform_shared.arn,
        aws_iam_policy.terraform_apply.arn,
      ]
    }
  }
}

output "ci_access_keys" {
  description = "Access keys for the two users, when var.create_access_keys is true. Read with `terraform output -json ci_access_keys`, copy into the GitHub secrets, then treat this root's state file as a credential."
  sensitive   = true
  value = var.create_access_keys ? {
    for k, v in aws_iam_access_key.ci : k => {
      access_key_id     = v.id
      secret_access_key = v.secret
    }
  } : null
}

output "instructions" {
  value = <<-EOT
What this created:
------------------
Two IAM users for the Terraform workflow in ../, with the permissions the main stack needs -- including the iam:ListRoles that 10-cluster-access.tf uses to resolve the IAM Identity Center permission sets at plan time.

  ${aws_iam_user.ci["plan"].name}
    ReadOnlyAccess + ${aws_iam_policy.terraform_shared.name}
    -> repo-level GitHub secrets, used by the automatic plan-on-main job

  ${aws_iam_user.ci["apply"].name}
    ReadOnlyAccess + ${aws_iam_policy.terraform_shared.name} + ${aws_iam_policy.terraform_apply.name}
    -> `aws-eks` environment secrets, used by the manual apply/destroy job


Access keys:
------------
${var.create_access_keys ? "Created. Read them with 'terraform output -json ci_access_keys' and put them in the GitHub secrets now. This root keeps state locally, so terraform.tfstate on this machine now contains both secret keys -- treat it as a credential, or 'terraform state rm' the keys once GitHub has them." : "Not created (create_access_keys = false). Either set it to true and re-apply, or create them out of band:\n\n    aws iam create-access-key --user-name ${aws_iam_user.ci["plan"].name}\n    aws iam create-access-key --user-name ${aws_iam_user.ci["apply"].name}\n\n  Creating them outside Terraform keeps the secret out of the state file entirely, at the cost of one manual step."}


Next:
-----
1) Put the keys in GitHub: the plan user's at repo level, the apply user's on the 'aws-eks' environment. Environment secrets win for jobs bound to that environment, which is what gives the two jobs different privilege with no extra workflow logic.
2) Assign the IAM Identity Center permission sets named in ../variables.tf (var.sso_access_permission_sets) to this account, if you have not already -- the main stack's plan fails on a permission set that has no role here.
3) Run the main stack: cd .. && terraform init && terraform plan
EOT
}
