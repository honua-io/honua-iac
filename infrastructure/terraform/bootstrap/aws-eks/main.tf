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
}

resource "aws_iam_user" "terraform" {
  #checkov:skip=CKV_AWS_273: Bootstrap uses an IAM user for non-SSO automation contexts.
  name = local.user_name
  tags = var.tags
}

resource "aws_iam_access_key" "terraform" {
  count = var.create_access_key ? 1 : 0
  user  = aws_iam_user.terraform.name
}

data "aws_iam_policy_document" "terraform" {
  #checkov:skip=CKV_AWS_110: Bootstrap policy requires broad permissions to provision infrastructure.
  #checkov:skip=CKV_AWS_111: Bootstrap policy requires write permissions across provisioned services.
  #checkov:skip=CKV_AWS_356: Resource scoping is handled by environment isolation.
  #checkov:skip=CKV_AWS_107: Bootstrap policy includes KMS and logging access for infrastructure setup.
  #checkov:skip=CKV_AWS_108: Bootstrap policy includes networking and cluster lifecycle actions.
  #checkov:skip=CKV_AWS_109: Bootstrap policy includes IAM management for EKS and node roles.
  statement {
    sid = "EksCoreInfra"
    actions = [
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
      "ec2:RunInstances",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "eks:AssociateAccessPolicy",
      "eks:Create*",
      "eks:Delete*",
      "eks:Describe*",
      "eks:DisassociateAccessPolicy",
      "eks:List*",
      "eks:TagResource",
      "eks:UntagResource",
      "eks:Update*",
      "autoscaling:Create*",
      "autoscaling:Delete*",
      "autoscaling:Describe*",
      "autoscaling:Set*",
      "autoscaling:TagResource",
      "autoscaling:UntagResource",
      "autoscaling:Update*",
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
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DeleteDashboards",
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
      "cloudwatch:Put*",
      "servicequotas:GetServiceQuota",
      "servicequotas:ListServiceQuotas",
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
      "ssm:AddTagsToResource",
      "ssm:Create*",
      "ssm:Delete*",
      "ssm:Describe*",
      "ssm:Get*",
      "ssm:List*",
      "ssm:Put*",
      "ssm:RemoveTagsFromResource",
      "tag:GetResources",
      "ssm:Update*"
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid = "IamForEks"
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
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
      "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
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
  #checkov:skip=CKV_AWS_40: Bootstrap policy attached directly to the automation user.
  user       = aws_iam_user.terraform.name
  policy_arn = aws_iam_policy.terraform.arn
}
