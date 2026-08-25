terraform {
  required_version = ">= 1.5, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  user_name = var.user_name != "" ? var.user_name : "${var.name_prefix}-${var.environment}"

  # HARD MARKER. This root provisions a long-lived IAM user, which the governed
  # AWS release lane refuses. The tags travel with the principal so an auditor
  # reading the account -- not just this file -- can tell the two paths apart.
  unsupported_posture_tags = {
    HonuaReleasePosture       = "unsupported-local-only"
    HonuaSupportedForRelease  = "false"
    HonuaCertifiedAlternative = "bootstrap/aws-exec-identity"
  }

  tags = merge(var.tags, local.unsupported_posture_tags)
}

# Fails loudly on every plan that asks for a long-lived access key. The key is
# the part that cannot be reconciled with the certified path at all.
check "unsupported_for_release_lane" {
  assert {
    condition     = !var.create_access_key
    error_message = "This bootstrap is LOCAL-ONLY and UNSUPPORTED for release: create_access_key mints a long-lived AWS credential. The certified lane uses bootstrap/aws-exec-identity with short-lived SSO/OIDC/STS federation."
  }
}

resource "aws_iam_user" "terraform" {
  #checkov:skip=CKV_AWS_273: Unsupported local-only bootstrap; the certified lane is bootstrap/aws-exec-identity.
  name = local.user_name
  tags = local.tags
}

resource "aws_iam_access_key" "terraform" {
  count = var.create_access_key ? 1 : 0
  user  = aws_iam_user.terraform.name
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
      "lambda:InvokeFunction",
      "lambda:List*",
      "lambda:PublishVersion",
      "lambda:RemovePermission",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:Update*",
      "apigateway:TagResource",
      "apigateway:DELETE",
      "apigateway:GET",
      "apigateway:PATCH",
      "apigateway:POST",
      "apigateway:TagResource",
      "apigateway:PUT",
      "logs:CreateLogDelivery",
      "logs:DeleteLogDelivery",
      "ec2:AllocateAddress",
      "ec2:AssociateRouteTable",
      "ec2:AttachInternetGateway",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:Create*",
      "ec2:Delete*",
      "ec2:Describe*",
      "ec2:DetachInternetGateway",
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
      "logs:DescribeResourcePolicies",
      "logs:Delete*",
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
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:DeleteObject",
      "s3:Get*",
      "s3:List*",
      "s3:PutBucket*",
      "s3:PutEncryptionConfiguration",
      "s3:PutObject",
      "ecr:BatchGetImage",
      "ecr:CreateRepository",
      "ecr:DeleteRepositoryPolicy",
      "ecr:DeleteRepository",
      "ecr:Describe*",
      "ecr:GetAuthorizationToken",
      "ecr:GetDownloadUrlForLayer",
      "ecr:GetRepositoryPolicy",
      "ecr:List*",
      "ecr:PutImage",
      "ecr:SetRepositoryPolicy",
      "ecr:TagResource",
      "ecr:UntagResource",
      "ecr:GetLifecyclePolicy",
      "ecr:PutLifecyclePolicy",
      "ecr:DeleteLifecyclePolicy",
      "ecr:PutImageScanningConfiguration"
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # --- GP on AWS Batch (Fargate Spot) -------------------------------------
  # Provisioning + lifecycle of the gated `enable_gp_batch` stack: compute
  # environment, job queue, job definition, plus the read/describe/tag calls an
  # apply makes. Without this an operator enabling enable_gp_batch fails at the
  # first batch:CreateComputeEnvironment. Region-scoped to the deploy region;
  # Batch resources do not support resource-level scoping at create time, so the
  # tight bound here is the region condition.
  statement {
    #checkov:skip=CKV_AWS_356: Batch create/describe/deregister actions do not support resource-level ARNs at provision time; scoped by aws:RequestedRegion.
    sid = "GpBatchProvisioning"
    actions = [
      "batch:CreateComputeEnvironment",
      "batch:UpdateComputeEnvironment",
      "batch:DeleteComputeEnvironment",
      "batch:CreateJobQueue",
      "batch:UpdateJobQueue",
      "batch:DeleteJobQueue",
      "batch:RegisterJobDefinition",
      "batch:DeregisterJobDefinition",
      "batch:Describe*",
      "batch:List*",
      "batch:TagResource",
      "batch:UntagResource"
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid = "IamForLambda"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:ListRoles",
      "iam:PassRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:CreateServiceLinkedRole"
    ]
    resources = ["*"]
  }

  # --- GP Batch role PassRole (scoped by consuming service) ----------------
  # The gated enable_gp_batch stack creates three roles — the Batch service
  # role, the Fargate task-execution role, and the GP job (task) role — and
  # AWS Batch / ECS must be able to assume them. iam:CreateRole / PutRolePolicy
  # / AttachRolePolicy for these roles are already covered by IamForLambda
  # above (resources "*"); this statement adds the PassRole grant, scoped via
  # iam:PassedToService so the deploy identity can only hand these roles to the
  # Batch and ECS-tasks principals (not to arbitrary services). Batch also
  # auto-provisions its service-linked role, covered by CreateServiceLinkedRole.
  statement {
    sid = "GpBatchPassRole"
    actions = [
      "iam:PassRole"
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "batch.amazonaws.com",
        "ecs-tasks.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_policy" "terraform" {
  name   = "${local.user_name}-policy"
  policy = data.aws_iam_policy_document.terraform.json
  tags   = local.tags
}

resource "aws_iam_user_policy_attachment" "terraform" {
  #checkov:skip=CKV_AWS_40: Bootstrap policy attached directly to the automation user.
  user       = aws_iam_user.terraform.name
  policy_arn = aws_iam_policy.terraform.arn
}
