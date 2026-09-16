################################################################################
# Karpenter
#
# Three layers, in dependency order:
#   1. module.karpenter  -- the AWS side: controller IAM role (via Pod Identity),
#      node IAM role + instance profile, cluster access entry for those nodes,
#      and the SQS queue/EventBridge rules that let Karpenter drain instances
#      ahead of a spot interruption or scheduled maintenance.
#   2. helm_release       -- the controller itself, on the managed node group.
#   3. EC2NodeClass/NodePool -- what Karpenter is actually allowed to launch.
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.3"

  cluster_name = module.eks.cluster_name

  namespace       = var.karpenter_namespace
  service_account = "karpenter"

  # Spot interruption / rebalance / instance-stop notices land on an SQS queue
  # the controller polls, so it can cordon and drain before EC2 pulls the node.
  enable_spot_termination = true

  # SSM lets the nodes be reached without SSH and without a bastion; the CNI
  # policy the module attaches by default covers everything else they need.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Project     = "Chamo"
  }
}

resource "helm_release" "karpenter" {
  name      = "karpenter"
  namespace = var.karpenter_namespace

  # Karpenter ships as an OCI artifact, not from a classic Helm repo, so the
  # registry URL goes in `chart` and `repository` stays unset.
  chart   = "oci://public.ecr.aws/karpenter/karpenter"
  version = var.karpenter_chart_version

  wait    = true
  timeout = 600

  values = [yamlencode({
    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }

    # The IAM role is attached through the Pod Identity association the module
    # creates, which keys off this exact service account name -- so the chart
    # must not annotate it with an IRSA role as well.
    serviceAccount = {
      name = module.karpenter.service_account
    }

    # Two replicas so a single node going away does not leave the cluster
    # without a provisioner; they lease-elect, only one is active.
    replicas = 2

    controller = {
      resources = {
        requests = { cpu = "0.5", memory = "512Mi" }
        limits   = { memory = "512Mi" }
      }
    }
  })]

  depends_on = [module.eks]
}

# Same Helm-CRD-then-CR race as time_sleep.wait_for_argocd_crds in
# 04-ingress-controller.tf: helm_release returning only means the chart's pods
# are up, not that the karpenter.sh/v1 and karpenter.k8s.aws/v1 CRDs it ships
# are discoverable through the API server yet. The two manifests below are CRs
# of exactly those kinds.
resource "time_sleep" "wait_for_karpenter_crds" {
  depends_on      = [helm_release.karpenter]
  create_duration = "30s"
}

# The AMI, subnets, security group, disk and IAM identity of anything Karpenter
# launches. Subnets and security group are matched by the karpenter.sh/discovery
# tag set in 01-vpc.tf and 02-eks.tf rather than by ID, so this survives the VPC
# being rebuilt.
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = local.karpenter_node_class
    }
    spec = {
      amiSelectorTerms = [{ alias = var.karpenter_node_ami_alias }]
      role             = module.karpenter.node_iam_role_name

      subnetSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = local.karpenter_discovery_tag }
      }]

      securityGroupSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = local.karpenter_discovery_tag }
      }]

      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs = {
          volumeSize          = "50Gi"
          volumeType          = "gp3"
          encrypted           = true
          deleteOnTermination = true
        }
      }]

      tags = {
        Environment              = var.environment
        Terraform                = "true"
        Project                  = "Chamo"
        "karpenter.sh/discovery" = local.karpenter_discovery_tag
      }
    }
  })

  depends_on = [time_sleep.wait_for_karpenter_crds]
}

# What Karpenter may provision, and when it takes capacity back. `limits` is the
# hard ceiling -- Karpenter stops adding nodes once the pool's requests reach
# it, leaving pods Pending rather than growing the bill without bound.
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = local.karpenter_node_pool
    }
    spec = {
      template = {
        metadata = {
          labels = { "role" = "workload" }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = local.karpenter_node_class
          }

          expireAfter = var.karpenter_node_expire_after

          requirements = [
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = var.karpenter_node_instance_categories
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = [tostring(var.karpenter_node_instance_generations_min - 1)]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = var.karpenter_node_capacity_types
            },
          ]
        }
      }

      # WhenEmptyOrUnderutilized also reclaims nodes whose pods would fit
      # elsewhere, not just fully empty ones -- that is where the savings are.
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = var.karpenter_node_consolidation_after
      }

      limits = {
        cpu = var.karpenter_node_cpu_limit
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_node_class]
}
