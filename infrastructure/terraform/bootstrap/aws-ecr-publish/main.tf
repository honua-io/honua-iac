# Image publish role of honua-server (deploy.yml and deploy-platform-images.yml).
#
# The role existed outside Terraform. This root makes its trust and permissions
# reviewable and drift-checked; import it before the first apply (README).
#
# Trust: only repo:honua-io/honua-server:environment:publish-images. That
# environment's deployment policy admits trunk, release/* and the publication
# tags (v*.*.* and honua-core-v*), so a workflow edited on any other branch, a pull request or another
# repository cannot assume the role. Built with components/aws-github-oidc
# (existing provider, exact subject, certification policy off).
#
# Permissions: registry login, and push, pull and create only for the
# publication repositories in the publication region. Inline or managed
# policies attached outside Terraform are removed on apply.

data "aws_caller_identity" "current" {}

locals {
  repository_arns = [
    for name in var.repository_names : "arn:aws:ecr:${var.ecr_region}:${data.aws_caller_identity.current.account_id}:repository/${name}"
  ]
}

module "oidc" {
  source = "../../components/aws-github-oidc"

  create_oidc_provider       = false
  existing_oidc_provider_arn = var.oidc_provider_arn

  github_owner             = "honua-io"
  github_repository        = "honua-server"
  github_oidc_subjects     = var.oidc_subjects
  role_name                = var.role_name
  cert_permissions_enabled = false

  name_prefix = "honua-server"
  environment = "publish"
  purpose     = "ecr-publish"
  tags        = { Owner = "honua-platform" }
}

resource "aws_iam_role_policy" "publish" {
  name = "ecr-publish"
  role = module.oidc.role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RegistryLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PublishRepository"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:CreateRepository",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:ListImages",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = local.repository_arns
      },
    ]
  })
}

resource "aws_iam_role_policies_exclusive" "publish" {
  role_name    = module.oidc.role_name
  policy_names = [aws_iam_role_policy.publish.name]
}

resource "aws_iam_role_policy_attachments_exclusive" "publish" {
  role_name   = module.oidc.role_name
  policy_arns = []
  # Write the replacement grant before detaching any managed policy the role still uses.
  depends_on = [aws_iam_role_policy.publish]
}
