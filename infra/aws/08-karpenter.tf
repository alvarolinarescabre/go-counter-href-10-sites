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

  # Not just module.karpenter: this chart creates Services, and the AWS Load
  # Balancer Controller registers a mutating webhook on every Service in the
  # cluster. Installed in parallel, Karpenter's Service lands while that webhook
  # exists but its backing pods do not, and the install dies with
  # "no endpoints available for service aws-load-balancer-webhook-service".
  # helm_release.aws_load_balancer_controller has wait = true, so depending on
  # it means the controller is actually ready first.
  #
  # module.eks, not just the cluster: this chart's pods need somewhere to RUN,
  # and the managed node group is the only compute that is not itself managed
  # from inside the cluster. Referencing module.eks.cluster_name (as the values
  # above do) builds an edge to the cluster and to nothing else, so on destroy
  # Terraform is free to delete the node group *in parallel* with this release.
  # That is what deadlocked the teardown on 2026-09-20: the system nodes went
  # away mid-drain, every controller went Pending, and the NodeClaim finalizers
  # that only Karpenter can clear were left with no Karpenter to clear them.
  # A depends_on over the whole module covers its node group too.
  depends_on = [module.eks, module.karpenter, helm_release.aws_load_balancer_controller]
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

  # This is what makes `terraform destroy` actually terminate the EC2 instances
  # Karpenter launched.
  #
  # Those instances belong to no Terraform resource and to no Auto Scaling
  # group: Karpenter owns them through NodeClaims, which carry the
  # karpenter.sh/termination finalizer and are owned by this NodePool. By
  # default kubectl_manifest issues the DELETE and returns immediately, so
  # Terraform would go on to remove the Karpenter controller and then the
  # cluster while the drain was still running -- leaving the instances alive,
  # their ENIs holding the private subnets, and the VPC destroy failing with
  # DependencyViolation.
  #
  # `wait = true` makes the provider block until the object is really gone, and
  # it waits for finalizers; it also switches delete_cascade to Foreground, so
  # the NodePool is not removed until every NodeClaim it owns is. A NodeClaim is
  # only removed once Karpenter has drained the node and terminated the
  # instance. Deterministic, rather than a sleep and a hope.
  wait           = true
  delete_cascade = "Foreground"

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
