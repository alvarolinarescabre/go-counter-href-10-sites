output "instructions" {
  value = <<-EOT
Update Kubeconfig:
------------------
Run this command to update ~/.kube/config file: 'aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}'


To Login ArgoCD:
----------------
${local.argocd_login_instructions}

Go Hit 10 App:
--------------
After deploy on ArgoCD, Run this command: 'kubectl get httproutes.gateway.networking.k8s.io -n counter-api' and uses the HOSTNAMES from 'counter-api' and uses it on you hosts file with your NLB address.


To Destroy:
-----------
Do this steps to destroy all:

1) terraform destroy

EOT
}
