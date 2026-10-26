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

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  user_name = var.user_name != "" ? var.user_name : "${var.name_prefix}-${var.environment}"

  partition      = data.aws_partition.current.partition
  account_id     = data.aws_caller_identity.current.account_id
  iam_arn_prefix = "arn:${local.partition}:iam::${local.account_id}"

  # IAM the deploy user may manage is confined to the workload namespace that
  # modules/aws-eks names its roles and policies under
  # (<name_prefix>-<environment>-eks-cluster-, -eks-node, -server, -gp-job, ...).
  workload_role_arns = [
    "${local.iam_arn_prefix}:role/${var.workload_name_prefix}*",
  ]
  workload_policy_arns = [
    "${local.iam_arn_prefix}:policy/${var.workload_name_prefix}*",
  ]

  # Deterministic ARNs for the identities this root creates, so the policy can
  # protect them without a dependency cycle.
  deployment_policy_arns = [
    "${local.iam_arn_prefix}:policy/${local.user_name}-policy",
    "${local.iam_arn_prefix}:policy/${local.user_name}-iam",
  ]
  workload_boundary_name = "${local.user_name}-workload-boundary"
  workload_boundary_arn  = "${local.iam_arn_prefix}:policy/${local.workload_boundary_name}"

  # Governed identities that may share the account (and the workload prefix)
  # and must never be handed to a service or rewritten by this user:
  # bootstrap/aws-exec-identity (*-deploy), bootstrap/aws-terraform-oidc
  # (honua-terraform-backend), and GitHub OIDC workflow roles (*-gha).
  protected_role_arns = distinct(concat([
    "${local.iam_arn_prefix}:role/*-deploy",
    "${local.iam_arn_prefix}:role/*-gha",
    "${local.iam_arn_prefix}:role/honua-terraform-backend*",
  ], var.protected_role_arns))

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
      "ec2:DisassociateAddress",
      "ec2:DetachInternetGateway",
      "ec2:DisassociateRouteTable",
      "ec2:Modify*",
      "ec2:RunInstances",
      "ec2:ReplaceRoute",
      "ec2:ReleaseAddress",
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
      "ssm:Update*"
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # GA cell data plane: RDS PostgreSQL, ElastiCache Redis, runtime secrets and
  # the custom-domain certificate (modules/aws-eks data-plane.tf / ingress.tf).
  statement {
    sid = "EksCellDataPlane"
    actions = [
      "rds:AddTagsToResource",
      "rds:CreateDBInstance",
      "rds:CreateDBParameterGroup",
      "rds:CreateDBSubnetGroup",
      "rds:DeleteDBInstance",
      "rds:DeleteDBParameterGroup",
      "rds:DeleteDBSubnetGroup",
      "rds:Describe*",
      "rds:ListTagsForResource",
      "rds:ModifyDBInstance",
      "rds:ModifyDBParameterGroup",
      "rds:ModifyDBSubnetGroup",
      "rds:RemoveTagsFromResource",
      "elasticache:AddTagsToResource",
      "elasticache:CreateCacheSubnetGroup",
      "elasticache:CreateReplicationGroup",
      "elasticache:DeleteCacheSubnetGroup",
      "elasticache:DeleteReplicationGroup",
      "elasticache:Describe*",
      "elasticache:ListTagsForResource",
      "elasticache:ModifyCacheSubnetGroup",
      "elasticache:ModifyReplicationGroup",
      "elasticache:RemoveTagsFromResource",
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:UpdateSecret",
      "acm:AddTagsToCertificate",
      "acm:DeleteCertificate",
      "acm:DescribeCertificate",
      "acm:ListTagsForCertificate",
      "acm:RemoveTagsFromCertificate",
      "acm:RequestCertificate"
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # Route53 is global, so it cannot carry the region condition above.
  statement {
    sid = "EksCellDns"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:GetChange",
      "route53:GetHostedZone",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource"
    ]
    resources = ["*"]
  }
}

# IAM management and the separation denials live in their own managed policy:
# together with the service grants above they exceed the 6144-character
# managed-policy quota. Both policies are attached to the user, and both are
# immutable to it.
data "aws_iam_policy_document" "iam" {
  #checkov:skip=CKV_AWS_109: IAM management is confined to the workload prefix and requires the workload boundary.
  #checkov:skip=CKV_AWS_110: Role creation and role-policy edits require the workload boundary, which excludes IAM.
  #checkov:skip=CKV_AWS_356: Only read-only discovery and explicit Deny statements use Resource "*".
  # --- IAM: workload roles only, always under the workload boundary ---------

  # Role lifecycle and inline/managed policy wiring for the EKS cluster role,
  # the managed node-group role and the server / GP job workload roles.
  # Creating a role, or changing what it is allowed to do, requires the role
  # to carry (or be created with) this root's workload permissions boundary,
  # so no role the user creates or edits can exceed the boundary, whatever
  # policy it is given.
  statement {
    sid    = "CreateBoundedWorkloadRoles"
    effect = "Allow"
    actions = [
      "iam:AttachRolePolicy",
      "iam:CreateRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePermissionsBoundary",
      "iam:PutRolePolicy",
    ]
    resources = local.workload_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.workload_boundary_arn]
    }
  }

  statement {
    sid    = "ManageWorkloadRoles"
    effect = "Allow"
    actions = [
      "iam:DeleteRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = local.workload_role_arns
  }

  statement {
    sid    = "ManageWorkloadPolicies"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:ListPolicyVersions",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = local.workload_policy_arns
  }

  # Read-only IAM discovery (managed-policy documents, externally supplied
  # role names). None of these can change a principal.
  statement {
    sid    = "IamReadOnlyDiscovery"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:GetRole",
      "iam:ListOpenIDConnectProviders",
      "iam:ListRoles",
    ]
    resources = ["*"]
  }

  # EKS, managed node groups, Auto Scaling, ELB, RDS and ElastiCache create
  # their own service-linked roles on first use in an account.
  statement {
    sid       = "CreateEksServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["${local.iam_arn_prefix}:role/aws-service-role/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "autoscaling.amazonaws.com",
        "eks-nodegroup.amazonaws.com",
        "eks.amazonaws.com",
        "elasticache.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
        "rds.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "PassWorkloadRolesToEksServicesOnly"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.workload_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "ec2.amazonaws.com",
        "eks.amazonaws.com",
        "pods.eks.amazonaws.com",
      ]
    }
  }

  # Node instance profiles share the workload prefix.
  statement {
    sid    = "ManageWorkloadInstanceProfiles"
    effect = "Allow"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = ["${local.iam_arn_prefix}:instance-profile/${var.workload_name_prefix}*"]
  }

  # IRSA only (workload_identity_mode = "irsa"): the cluster's own OIDC
  # provider. EKS issuer paths are server-assigned, so the provider is scoped
  # to this region's EKS issuer namespace rather than the name prefix.
  statement {
    sid    = "ManageEksOidcProviders"
    effect = "Allow"
    actions = [
      "iam:AddClientIDToOpenIDConnectProvider",
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
    ]
    resources = ["${local.iam_arn_prefix}:oidc-provider/oidc.eks.${var.aws_region}.amazonaws.com/id/*"]
  }

  # --- separation denials (ported from bootstrap/aws-exec-identity) ---------

  statement {
    sid    = "DenyLongLivedCredentials"
    effect = "Deny"
    actions = [
      "iam:AttachUserPolicy",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:CreateServiceSpecificCredential",
      "iam:CreateUser",
      "iam:PutUserPolicy",
      "iam:ResetServiceSpecificCredential",
      "iam:UpdateAccessKey",
      "iam:UpdateLoginProfile",
      "iam:UploadSSHPublicKey",
    ]
    resources = ["*"]
  }

  # A role whose trust policy names this user directly would be assumable
  # without an identity-policy grant; refuse every role hop outright.
  statement {
    sid    = "DenyRoleChaining"
    effect = "Deny"
    actions = [
      "sts:AssumeRole",
      "sts:AssumeRoleWithSAML",
      "sts:AssumeRoleWithWebIdentity",
      "sts:GetFederationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "DenyPassingPrivilegedRoles"
    effect    = "Deny"
    actions   = ["iam:PassRole"]
    resources = local.protected_role_arns
  }

  # The deploy user's own policy and the workload boundary may match the
  # workload prefix; neither may be rewritten, and no protected role may be
  # touched.
  statement {
    sid    = "DenyDeploymentIdentityMutation"
    effect = "Deny"
    actions = [
      "iam:AttachRolePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePermissionsBoundary",
      "iam:PutRolePolicy",
      "iam:SetDefaultPolicyVersion",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = concat(
      local.deployment_policy_arns,
      [local.workload_boundary_arn],
      local.protected_role_arns,
    )
  }

  statement {
    sid       = "DenyBoundaryRemoval"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }
}

# Ceiling for every role the deploy user creates. Workload roles keep whatever
# service permissions their own policies grant, but can never administer IAM,
# the organization or the account, and can never assume another role. The one
# IAM call let through is CreateServiceLinkedRole, which AmazonEKSClusterPolicy
# uses for the ELB service-linked role.
data "aws_iam_policy_document" "workload_boundary" {
  #checkov:skip=CKV_AWS_107: A permissions boundary is a ceiling, not a grant; the roles' own policies scope access.
  #checkov:skip=CKV_AWS_108: A permissions boundary is a ceiling, not a grant; the roles' own policies scope access.
  #checkov:skip=CKV_AWS_109: The ceiling is NotAction iam:*; checkov reads NotAction as a grant of everything.
  #checkov:skip=CKV_AWS_110: The ceiling is NotAction iam:*; checkov reads NotAction as a grant of everything.
  #checkov:skip=CKV_AWS_111: A permissions boundary is a ceiling, not a grant; the roles' own policies scope access.
  #checkov:skip=CKV_AWS_356: A permissions boundary is a ceiling, not a grant; the roles' own policies scope resources.
  statement {
    sid    = "WorkloadServiceCeiling"
    effect = "Allow"
    not_actions = [
      "account:*",
      "iam:*",
      "organizations:*",
      "sts:AssumeRole",
      "sts:AssumeRoleWithSAML",
      "sts:AssumeRoleWithWebIdentity",
      "sts:GetFederationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "AllowServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::*:role/aws-service-role/*"]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = local.workload_boundary_name
  description = "Permissions boundary required on every role created by the local-only ${local.user_name} bootstrap user."
  policy      = data.aws_iam_policy_document.workload_boundary.json
  tags        = local.tags
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

resource "aws_iam_policy" "iam" {
  name        = "${local.user_name}-iam"
  description = "Prefix-scoped, boundary-enforced IAM management and separation denials for the local-only ${local.user_name} bootstrap user."
  policy      = data.aws_iam_policy_document.iam.json
  tags        = local.tags
}

resource "aws_iam_user_policy_attachment" "iam" {
  #checkov:skip=CKV_AWS_40: Bootstrap policy attached directly to the automation user.
  user       = aws_iam_user.terraform.name
  policy_arn = aws_iam_policy.iam.arn
}
