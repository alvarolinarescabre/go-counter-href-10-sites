module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.3"

  name               = local.name_cluster
  kubernetes_version = local.cluster_version

  endpoint_public_access                   = true
  endpoint_public_access_cidrs             = ["0.0.0.0/0"]
  enable_cluster_creator_admin_permissions = true

  # enable_cluster_creator_admin_permissions above only grants access to
  # whichever identity ran `terraform apply` (the GitHub Actions IAM user) --
  # anyone else, e.g. a human running kubectl from their own machine, needs
  # an explicit access entry. See var.additional_cluster_admin_arns.
  access_entries = {
    for arn in var.additional_cluster_admin_arns : replace(arn, "/[^a-zA-Z0-9]/", "-") => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  compute_config = {
    enabled    = true
    node_pools = ["general-purpose"]
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Project     = "Chamo"
  }
}
