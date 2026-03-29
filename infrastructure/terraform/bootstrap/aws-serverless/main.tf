terraform {
  required_version = ">= 1.5, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.30"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  user_name                       = var.user_name != "" ? var.user_name : "${var.name_prefix}-${var.environment}"
  role_name                       = var.role_name != "" ? var.role_name : "${local.user_name}-federated"
  oidc_provider_match             = trimspace(var.oidc_provider_arn) != "" ? regexall("oidc-provider/(.+)$", trimspace(var.oidc_provider_arn)) : []
  oidc_provider_key               = length(local.oidc_provider_match) > 0 ? local.oidc_provider_match[0][0] : ""
  managed_name_globs              = distinct(compact([for glob in var.managed_name_globs : trimspace(glob)]))
  service_linked_role_services    = ["lambda.amazonaws.com", "replicator.lambda.amazonaws.com", "ops.apigateway.amazonaws.com"]
  additional_ecr_repository_names = distinct(compact([for name in var.additional_ecr_repository_names : trimspace(name)]))
  managed_role_arns = [
    for glob in local.managed_name_globs : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${glob}"
  ]
  managed_policy_arns = [
    for glob in local.managed_name_globs : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${glob}"
  ]
  managed_bucket_arns = [for glob in local.managed_name_globs : "arn:${data.aws_partition.current.partition}:s3:::${glob}"]
  managed_lambda_arns = [
    for glob in local.managed_name_globs : "arn:${data.aws_partition.current.partition}:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${glob}"
  ]
  managed_ecr_repository_arns = [
    for glob in local.managed_name_globs : "arn:${data.aws_partition.current.partition}:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${glob}"
  ]
  additional_ecr_repository_arns = [
    for name in local.additional_ecr_repository_names : "arn:${data.aws_partition.current.partition}:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${name}"
  ]
}

check "bootstrap_identity_surface" {
  assert {
    condition     = var.create_iam_user || (trimspace(var.oidc_provider_arn) != "" && length(var.oidc_subjects) > 0)
    error_message = "create_iam_user must be true, or oidc_provider_arn and oidc_subjects must be configured."
  }
}

check "access_key_requires_user" {
  assert {
    condition     = !var.create_access_key || var.create_iam_user
    error_message = "create_access_key requires create_iam_user = true."
  }
}

check "oidc_inputs_together" {
  assert {
    condition     = (trimspace(var.oidc_provider_arn) == "" && length(var.oidc_subjects) == 0) || (trimspace(var.oidc_provider_arn) != "" && length(var.oidc_subjects) > 0)
    error_message = "oidc_provider_arn and oidc_subjects must be configured together."
  }
}

check "oidc_provider_arn_format" {
  assert {
    condition     = trimspace(var.oidc_provider_arn) == "" || length(local.oidc_provider_match) > 0
    error_message = "oidc_provider_arn must include an oidc-provider/<issuer-path> suffix."
  }
}

resource "aws_iam_user" "terraform" {
  count = var.create_iam_user ? 1 : 0
  #checkov:skip=CKV_AWS_273: Bootstrap uses an IAM user for non-SSO automation contexts.
  name = local.user_name
  tags = var.tags
}

resource "aws_iam_access_key" "terraform" {
  count = var.create_access_key ? 1 : 0
  user  = aws_iam_user.terraform[0].name
}

data "aws_iam_policy_document" "terraform" {
  #checkov:skip=CKV_AWS_110: Bootstrap policy requires broad permissions to provision infrastructure.
  #checkov:skip=CKV_AWS_111: Bootstrap policy requires write permissions across provisioned services.
  #checkov:skip=CKV_AWS_356: Resource scoping is handled by environment isolation.
  #checkov:skip=CKV_AWS_107: Bootstrap policy includes Secrets/KMS access for infrastructure setup.
  #checkov:skip=CKV_AWS_108: Bootstrap policy includes networking and logging actions.
  #checkov:skip=CKV_AWS_109: Bootstrap policy includes IAM management for execution roles.
  statement {
    sid = "ServerlessCoreInfra"
    actions = [
      "lambda:AddPermission",
      "lambda:Create*",
      "lambda:Delete*",
      "lambda:Get*",
      "lambda:List*",
      "lambda:PublishVersion",
      "lambda:RemovePermission",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:Update*",
      "apigateway:DELETE",
      "apigateway:GET",
      "apigateway:PATCH",
      "apigateway:POST",
      "apigateway:PUT",
      "apigateway:TagResource",
      "apigateway:UntagResource",
      "ec2:AllocateAddress",
      "ec2:AssociateRouteTable",
      "ec2:AttachInternetGateway",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:Create*",
      "ec2:Delete*",
      "ec2:Describe*",
      "ec2:DetachInternetGateway",
      "ec2:DisassociateAddress",
      "ec2:DisassociateRouteTable",
      "ec2:Modify*",
      "ec2:ReplaceRoute",
      "ec2:ReleaseAddress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "rds:AddTagsToResource",
      "rds:Create*",
      "rds:Delete*",
      "rds:Describe*",
      "rds:ListTagsForResource",
      "rds:Modify*",
      "rds:RemoveTagsFromResource",
      "elasticache:AddTagsToResource",
      "elasticache:Create*",
      "elasticache:Delete*",
      "elasticache:Describe*",
      "elasticache:List*",
      "elasticache:Modify*",
      "elasticache:RemoveTagsFromResource",
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:GetSecretValue",
      "secretsmanager:ListSecrets",
      "secretsmanager:PutSecretValue",
      "secretsmanager:RestoreSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:UpdateSecret",
      "kms:CreateAlias",
      "kms:CreateKey",
      "kms:Decrypt",
      "kms:DeleteAlias",
      "kms:Describe*",
      "kms:EnableKeyRotation",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:ListAliases",
      "kms:ListResourceTags",
      "kms:PutKeyPolicy",
      "kms:ScheduleKeyDeletion",
      "kms:TagResource",
      "kms:UntagResource",
      "logs:Create*",
      "logs:CreateLogDelivery",
      "logs:Delete*",
      "logs:DeleteLogDelivery",
      "logs:Describe*",
      "logs:GetLogDelivery",
      "logs:ListLogDeliveries",
      "logs:ListTagsForResource",
      "logs:PutResourcePolicy",
      "logs:PutRetentionPolicy",
      "logs:TagLogGroup",
      "logs:UntagLogGroup",
      "logs:UpdateLogDelivery",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DeleteDashboards",
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
      "cloudwatch:Put*",
      "servicequotas:GetServiceQuota",
      "ecr:Describe*",
      "ecr:GetAuthorizationToken",
      "ecr:List*",
      "tag:GetResources"
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid = "S3ForServerless"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:DeleteObject",
      "s3:DeleteObjectTagging",
      "s3:DeleteObjectVersion",
      "s3:DeleteObjectVersionTagging",
      "s3:Get*",
      "s3:List*",
      "s3:PutBucket*",
      "s3:PutEncryptionConfiguration",
      "s3:PutObject"
    ]
    resources = concat(
      local.managed_bucket_arns,
      [for arn in local.managed_bucket_arns : "${arn}/*"]
    )
  }

  statement {
    sid = "LambdaInvokeManagedFunctions"
    actions = [
      "lambda:InvokeFunction"
    ]
    resources = local.managed_lambda_arns
  }

  statement {
    sid = "EcrRepositoryLifecycleForServerless"
    actions = [
      "ecr:BatchGetImage",
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:GetDownloadUrlForLayer",
      "ecr:PutImage",
      "ecr:SetRepositoryPolicy",
      "ecr:TagResource",
      "ecr:UntagResource"
    ]
    resources = distinct(concat(local.managed_ecr_repository_arns, local.additional_ecr_repository_arns))
  }

  statement {
    sid = "IamRoleLifecycleForLambda"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:TagRole",
      "iam:UntagRole"
    ]
    resources = local.managed_role_arns
  }

  statement {
    sid = "IamPolicyLifecycleForLambda"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy"
    ]
    resources = local.managed_policy_arns
  }

  statement {
    sid = "IamPassManagedRolesForLambda"
    actions = [
      "iam:PassRole"
    ]
    resources = local.managed_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  statement {
    sid = "IamServiceLinkedRolesForLambda"
    actions = [
      "iam:CreateServiceLinkedRole"
    ]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "iam:AWSServiceName"
      values   = local.service_linked_role_services
    }
  }
}

resource "aws_iam_policy" "terraform" {
  name   = "${local.user_name}-policy"
  policy = data.aws_iam_policy_document.terraform.json
  tags   = var.tags
}

resource "aws_iam_user_policy_attachment" "terraform" {
  count = var.create_iam_user ? 1 : 0
  #checkov:skip=CKV_AWS_40: Bootstrap policy attached directly to the automation user.
  user       = aws_iam_user.terraform[0].name
  policy_arn = aws_iam_policy.terraform.arn
}

data "aws_iam_policy_document" "terraform_oidc_assume" {
  count = trimspace(var.oidc_provider_arn) != "" && length(var.oidc_subjects) > 0 ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_key}:aud"
      values   = var.oidc_audiences
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_provider_key}:sub"
      values   = var.oidc_subjects
    }
  }
}

resource "aws_iam_role" "terraform" {
  count = trimspace(var.oidc_provider_arn) != "" && length(var.oidc_subjects) > 0 ? 1 : 0

  name               = local.role_name
  assume_role_policy = data.aws_iam_policy_document.terraform_oidc_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "terraform" {
  count = trimspace(var.oidc_provider_arn) != "" && length(var.oidc_subjects) > 0 ? 1 : 0

  role       = aws_iam_role.terraform[0].name
  policy_arn = aws_iam_policy.terraform.arn
}
