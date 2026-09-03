# Registry for the counter-api image.
#
# ECR instead of GHCR so that nothing in the cluster holds registry
# credentials: EKS Auto Mode's node IAM role carries
# AmazonEC2ContainerRegistryPullOnly (see the eks module's
# aws_iam_role_policy_attachment.eks_auto), so kubelet authenticates to this
# repository with the node's own role. No imagePullSecret, nothing to rotate,
# and the pull never leaves the account.

resource "aws_ecr_repository" "counter_api" {
  name = var.ecr_repository_name

  # The pipeline tags every image sha-<commit>, which is unique by
  # construction, so an overwrite can only ever be a mistake — let the registry
  # reject it. The flip side: the pipeline must not push a floating tag such as
  # `latest`, because the second push of it would fail.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # `terraform destroy` fails on a repository that still holds images, and this
  # stack is built to be torn down.
  force_delete = true

  tags = {
    Name = var.ecr_repository_name
  }
}

resource "aws_ecr_lifecycle_policy" "counter_api" {
  repository = aws_ecr_repository.counter_api.name

  # Rules are evaluated in rulePriority order and an image is only ever matched
  # by the first rule that selects it.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images (leftovers from overwritten manifests)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.ecr_untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the most recent sha- builds"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = var.ecr_keep_last_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
