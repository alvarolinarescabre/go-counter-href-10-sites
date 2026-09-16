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
  # anyone else, e.g. a human running kubectl from their own machine, needs an
  # explicit access entry. Two ways in, and they are deliberately different:
  #
  #   - local.sso_access_entries -- the IAM Identity Center permission sets
  #     (10-cluster-access.tf). This is how people should get in: no standing
  #     credentials at all, and access follows group membership in the identity
  #     store rather than a `terraform apply`.
  #   - local.break_glass_access_entries -- the emergency cluster-admin role,
  #     deliberately reachable without Identity Center.
  #   - var.additional_cluster_admin_arns -- a raw list of principal ARNs
  #     granted cluster-admin directly. An escape hatch for a machine principal
  #     that cannot go through either of the above; anything a human uses
  #     belongs in Identity Center instead.
  access_entries = merge(
    local.sso_access_entries,
    local.break_glass_access_entries,
    {
      for arn in var.additional_cluster_admin_arns : replace(arn, "/[^a-zA-Z0-9]/", "-") => {
        principal_arn = arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
  )

  # EKS Auto Mode, explicitly off. It bundles its own (AWS-managed, opaque)
  # Karpenter, load balancer controller and EBS CSI driver, which would fight
  # with the Karpenter we run ourselves in 08-karpenter.tf -- two provisioners
  # racing to satisfy the same pending pods. `enabled = false` is not the same
  # as deleting this block: the block is what emits the API fields that turn
  # Auto Mode, its ELB integration and its block storage back off on a cluster
  # that already has them on.
  compute_config = {
    enabled = false
  }

  # Without Auto Mode nothing installs the cluster's base components any more,
  # so they become ordinary addons:
  #   - vpc-cni / kube-proxy must exist BEFORE the first node joins, or nodes
  #     come up NotReady with no pod networking (before_compute = true).
  #   - coredns schedules onto nodes, so it can only come after them.
  #   - eks-pod-identity-agent is what backs the Karpenter controller's IAM
  #     credentials; the karpenter submodule associates a role with its service
  #     account through Pod Identity, and without the agent that association
  #     resolves to nothing and Karpenter cannot call EC2.
  addons = {
    vpc-cni = {
      before_compute = true
    }
    kube-proxy = {
      before_compute = true
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    coredns = {}
  }

  # Karpenter cannot create the node its own controller runs on, so a managed
  # node group has to carry Karpenter itself plus the rest of the control-plane
  # -adjacent workloads (CoreDNS, Argo CD, kgateway). Application pods are
  # expected to land on Karpenter-provisioned capacity instead.
  eks_managed_node_groups = {
    system = {
      name = local.node_groups_name

      ami_type       = local.ami_type
      instance_types = var.node_group_instance_types
      capacity_type  = var.node_group_capacity_type

      # Not `disk_size`: the module builds a custom launch template for the
      # group, and the API rejects disk_size alongside one -- the module drops
      # the value silently, leaving nodes on the AMI's default 20 GiB. The
      # volume has to be described on the launch template instead.
      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_group_disk_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      min_size     = var.node_group_min_size
      max_size     = var.node_group_max_size
      desired_size = var.node_group_desired_size

      labels = {
        "role" = "system"
      }
    }
  }

  # Karpenter's EC2NodeClass finds the security group to attach new nodes to by
  # this tag -- see local.karpenter_discovery_tag.
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.karpenter_discovery_tag
  }

  # The module only opens node-to-node traffic on ports 1025-65535 (plus DNS).
  # With the VPC CNI, pods share their node's security group, so a pod on one
  # node reaching a pod on another over a port below 1025 -- e.g. the gateway
  # proxy to counter-api on :80 -- times out ("no healthy upstream"). Allow all
  # traffic between nodes that carry this security group.
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Project     = "Chamo"
  }
}
