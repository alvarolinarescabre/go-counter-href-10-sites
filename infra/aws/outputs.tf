output "update_kubeconfig_command" {
  description = "Command to update kubeconfig with EKS cluster credentials"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_url" {
  description = "Registry path the deploy workflow pushes to and image.repository points at in the Helm values."
  value       = aws_ecr_repository.counter_api.repository_url
}

output "cluster_access" {
  description = "Who can reach the cluster and how: the Identity Center permission sets mapped to EKS access entries, and the break-glass role for when Identity Center is unavailable."
  value = {
    sso = {
      for k, v in var.sso_access_permission_sets : k => {
        role_arn      = local.sso_role_arns[k]
        access_policy = v.access_policy
        scope         = v.namespaces == null ? "cluster-wide" : join(", ", v.namespaces)
      }
    }
    break_glass = var.break_glass_role_enabled ? {
      role_arn          = aws_iam_role.break_glass[0].arn
      assume_policy_arn = aws_iam_policy.break_glass[0].arn
      mfa_required      = var.break_glass_require_mfa
    } : null
  }
}

output "instructions" {
  value = <<-EOT
Update Kubeconfig:
------------------
Run this command to update ~/.kube/config file: 'aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}'


To Login ArgoCD:
----------------
${local.argocd_login_instructions}

Human Access (IAM Identity Center):
-----------------------------------
Nobody uses their own long-lived IAM credentials. People sign in to the Identity Center access portal, pick a permission set, and the role they land on is already mapped to a Kubernetes access level:

${length(var.sso_access_permission_sets) == 0 ? "  (none configured -- var.sso_access_permission_sets is empty)" : join("\n", [for k, v in var.sso_access_permission_sets : format("  %-24s %-14s %s", k, v.access_policy, v.namespaces == null ? "cluster-wide" : join(", ", v.namespaces))])}

Granting or revoking a person's access is group membership in the identity store -- not a terraform apply. Assigning a NEW permission set to this account is, though: add it to var.sso_access_permission_sets and re-apply, or its role has no access entry and kubectl is denied everything.

Configure the CLI once (creates an SSO-backed profile), then point kubeconfig at the cluster through it:

  aws configure sso --profile ${local.name}-eks
  aws sso login --profile ${local.name}-eks
  aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --profile ${local.name}-eks

Check what the cluster thinks you are: 'kubectl auth whoami', and what you may do: 'kubectl auth can-i --list'


Break-glass (Identity Center is down):
--------------------------------------
${var.break_glass_role_enabled ? join("\n", [
  "  Role:          ${aws_iam_role.break_glass[0].arn}",
  "  Assume policy: ${aws_iam_policy.break_glass[0].arn}${var.break_glass_require_mfa ? "  (MFA required)" : ""}",
  "",
  "  The assume policy is attached to nobody by default. During an incident, attach it, use it, then detach it:",
  "    aws iam attach-user-policy --user-name <them> --policy-arn ${aws_iam_policy.break_glass[0].arn}",
  "    aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --role-arn ${aws_iam_role.break_glass[0].arn} --alias ${module.eks.cluster_name}-break-glass",
  "    aws iam detach-user-policy --user-name <them> --policy-arn ${aws_iam_policy.break_glass[0].arn}",
  "",
  "  Every assume-role on it is in CloudTrail under the human's own identity -- review them afterwards.",
]) : "  Disabled (break_glass_role_enabled = false). If Identity Center is unavailable, the only remaining admins are var.additional_cluster_admin_arns and whichever principal ran terraform apply."}


Cluster Compute:
----------------
The cluster runs a ${var.node_group_desired_size}-node managed group of ${join(", ", var.node_group_instance_types)} (min ${var.node_group_min_size}, max ${var.node_group_max_size}) for CoreDNS, Karpenter itself, the AWS Load Balancer Controller, Argo CD and kgateway. Everything beyond that is provisioned on demand by Karpenter, capped at ${var.karpenter_node_cpu_limit} vCPU.

Check what Karpenter is doing: 'kubectl get nodepool,ec2nodeclass' and 'kubectl get nodeclaims'
Controller logs: 'kubectl -n ${var.karpenter_namespace} logs -l app.kubernetes.io/name=karpenter -f'
Tell the two kinds of node apart: 'kubectl get nodes -L karpenter.sh/nodepool -L node.kubernetes.io/instance-type -L karpenter.sh/capacity-type'


Container Image:
----------------
The deploy workflow pushes to '${aws_ecr_repository.counter_api.repository_url}'.
That exact string must be image.repository in deploy/helm/counter-api/values.yaml; nodes pull it with their own IAM role, so no imagePullSecret is involved.


Go Hit 10 App:
--------------
After deploy on ArgoCD, Run this command: 'kubectl get httproutes.gateway.networking.k8s.io -n counter-api' and uses the HOSTNAMES from 'counter-api' and uses it on you hosts file with your NLB address.


To Destroy:
-----------
Do this steps to destroy all:

1) terraform destroy

EOT
}
