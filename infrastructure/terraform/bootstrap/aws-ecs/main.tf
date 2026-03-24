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
  user_name          = var.user_name != "" ? var.user_name : "${var.name_prefix}-${var.environment}"
  role_name          = var.role_name != "" ? var.role_name : "${local.user_name}-federated"
  oidc_provider_key  = var.oidc_provider_arn != "" ? split("oidc-provider/", var.oidc_provider_arn)[1] : ""
  managed_name_globs = distinct(compact([for glob in var.managed_name_globs : trimspace(glob)]))
  managed_role_arns  = [for glob in local.managed_name_globs : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${glob}"]
  managed_policy_arns = [
    for glob in local.managed_name_globs : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${glob}"
  ]
  managed_bucket_arns = [for glob in local.managed_name_globs : "arn:${data.aws_partition.current.partition}:s3:::${glob}"]
}

check "bootstrap_identity_surface" {
  assert {
    condition     = var.create_iam_user || (trimspace(var.oidc_provider_arn) != "" && length(var.oidc_subjects) > 0)
    error_message = "Enable create_iam_user or configure oidc_provider_arn with at least one oidc_subject."
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
  #checkov:skip=CKV_AWS_109: Bootstrap policy includes IAM management for task roles.
  statement {
    sid = "EcsCoreInfra"
    actions = [
      "ec2:AllocateAddress",
      "ec2:AssociateRouteTable",
      "ec2:AttachInternetGateway",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:Create*",
      "ec2:CreateTags",
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
      "ecs:Create*",
      "ecs:Delete*",
      "ecs:DeregisterTaskDefinition",
      "ecs:Describe*",
      "ecs:List*",
      "ecs:RegisterTaskDefinition",
      "ecs:TagResource",
      "ecs:UntagResource",
      "ecs:Update*",
      "elasticache:AddTagsToResource",
      "elasticache:Create*",
      "elasticache:Delete*",
      "elasticache:Describe*",
      "elasticache:List*",
      "elasticache:Modify*",
      "elasticache:RemoveTagsFromResource",
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:Create*",
      "elasticloadbalancing:Delete*",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:Describe*",
      "elasticloadbalancing:Modify*",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:RemoveTags",
      "elasticloadbalancing:Set*",
      "logs:Create*",
      "logs:Delete*",
      "logs:Describe*",
      "logs:ListTagsForResource",
      "logs:PutRetentionPolicy",
      "logs:TagLogGroup",
      "logs:UntagLogGroup",
      "rds:AddTagsToResource",
      "rds:Create*",
      "rds:Delete*",
      "rds:Describe*",
      "rds:ListTagsForResource",
      "rds:Modify*",
      "rds:RemoveTagsFromResource",
      "servicequotas:GetServiceQuota",
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
      "acm:AddTagsToCertificate",
      "acm:DeleteCertificate",
      "acm:DescribeCertificate",
      "acm:ListCertificates",
      "acm:RemoveTagsFromCertificate",
      "acm:RequestCertificate",
      "route53:ChangeResourceRecordSets",
      "route53:GetChange",
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
      "tag:GetResources",
      "wafv2:AssociateWebACL",
      "wafv2:CreateWebACL",
      "wafv2:DeleteWebACL",
      "wafv2:DisassociateWebACL",
      "wafv2:GetWebACL",
      "wafv2:ListWebACLs",
      "wafv2:TagResource",
      "wafv2:UntagResource",
      "wafv2:UpdateWebACL",
      "application-autoscaling:DeleteScalingPolicy",
      "application-autoscaling:DeregisterScalableTarget",
      "application-autoscaling:Describe*",
      "application-autoscaling:ListTagsForResource",
      "application-autoscaling:PutScalingPolicy",
      "application-autoscaling:RegisterScalableTarget",
      "application-autoscaling:TagResource",
      "application-autoscaling:UntagResource"
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid = "S3ForEcs"
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
    sid = "IamReadForEcsTasks"
    actions = [
      "iam:ListRoles"
    ]
    resources = ["*"]
  }

  statement {
    sid = "IamRoleLifecycleForEcsTasks"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:ListInstanceProfilesForRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:TagRole",
      "iam:UntagRole"
    ]
    resources = local.managed_role_arns
  }

  statement {
    sid = "IamPolicyLifecycleForEcsTasks"
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
    sid = "IamPassManagedRolesForEcsTasks"
    actions = [
      "iam:PassRole"
    ]
    resources = local.managed_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid = "IamServiceLinkedRolesForEcs"
    actions = [
      "iam:CreateServiceLinkedRole"
    ]
    resources = ["*"]
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
