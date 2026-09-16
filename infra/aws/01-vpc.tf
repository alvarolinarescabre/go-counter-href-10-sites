module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5"

  name = local.name_vpc

  cidr            = local.cidr
  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.name_cluster}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.name_cluster}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1

    # Karpenter picks the subnets for the nodes it provisions by this tag
    # (subnetSelectorTerms in the EC2NodeClass, 08-karpenter.tf). Only the
    # private subnets carry it, so provisioned nodes never get a public IP.
    "karpenter.sh/discovery" = local.karpenter_discovery_tag
  }

  map_public_ip_on_launch = true
}