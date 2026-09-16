module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.25.0"

  cluster_name = module.eks.cluster_name

  # Name needs to match role name passed to the EC2NodeClass
  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = "${local.name}-karpenter-node"
  create_pod_identity_association = true
  enable_inline_policy            = true

  # Used to attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Project     = "Chamo"
  }
}

# EC2 needs the account-wide Spot service-linked role before it will launch a
# spot instance, and the Karpenter controller role is not allowed to create it
# on the fly (AuthFailure.ServiceLinkedRoleCreationNotPermitted). Only created
# when spot is one of the allowed capacity types.
resource "aws_iam_service_linked_role" "spot" {
  count            = contains(var.karpenter_node_capacity_types, "spot") ? 1 : 0
  aws_service_name = "spot.amazonaws.com"
}

resource "helm_release" "karpenter" {
  namespace           = "kube-system"
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = "1.2.0"
  wait                = false

  values = [
    <<-EOT
    dnsPolicy: Default
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    webhook:
      enabled: false
    EOT
  ]

  depends_on = [module.karpenter]
}

# Wait for Karpenter CRDs to be registered before creating EC2NodeClass and NodePool
resource "time_sleep" "wait_for_karpenter_crds" {
  depends_on      = [helm_release.karpenter]
  create_duration = "30s"
}

# EC2NodeClass defines the AMI, subnets, security group, and IAM role for Karpenter nodes
resource "kubectl_manifest" "karpenter_ec2_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      amiSelectorTerms = [
        { alias = var.karpenter_node_ami_alias }
      ]
      role = module.karpenter.node_iam_role_name

      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.karpenter_discovery_tag
          }
        }
      ]

      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.karpenter_discovery_tag
          }
        }
      ]

      tags = {
        "karpenter.sh/discovery" = local.karpenter_discovery_tag
      }
    }
  })

  depends_on = [time_sleep.wait_for_karpenter_crds]
}

# NodePool defines what Karpenter can provision and consolidation policies
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "default"
    }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          requirements = [
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = var.karpenter_node_instance_categories
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = var.karpenter_node_architectures
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = var.karpenter_node_capacity_types
            },
            {
              key      = "karpenter.k8s.aws/instance-cpu"
              operator = "In"
              values   = ["4", "8", "16", "32"]
            },
            {
              key      = "karpenter.k8s.aws/instance-hypervisor"
              operator = "In"
              values   = ["nitro"]
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = [tostring(var.karpenter_node_instance_generations_min - 1)]
            }
          ]
        }
      }

      limits = {
        cpu = var.karpenter_node_cpu_limit
      }

      disruption = {
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = var.karpenter_node_consolidation_after
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_ec2_node_class, aws_iam_service_linked_role.spot]
}

# Sample workload to exercise Karpenter scaling: 5 pause pods requesting 1 CPU each
# resource "kubectl_manifest" "karpenter_inflate" {
#   yaml_body = yamlencode({
#     apiVersion = "apps/v1"
#     kind       = "Deployment"
#     metadata = {
#       name      = "inflate"
#       namespace = "default"
#     }
#     spec = {
#       replicas = 5
#       selector = {
#         matchLabels = {
#           app = "inflate"
#         }
#       }
#       template = {
#         metadata = {
#           labels = {
#             app = "inflate"
#           }
#         }
#         spec = {
#           terminationGracePeriodSeconds = 0
#           containers = [
#             {
#               name  = "inflate"
#               image = "public.ecr.aws/eks-distro/kubernetes/pause:3.7"
#               resources = {
#                 requests = {
#                   cpu = "1"
#                 }
#               }
#             }
#           ]
#         }
#       }
#     }
#   })

#   depends_on = [kubectl_manifest.karpenter_node_pool]
# }
