###############################################################################
# Short-lived AWS execution identity for the governed Honua deployment lane
# (honua-iac#149).
#
# Four permission surfaces, four distinct identities:
#
#   1. BACKEND ACCESS   reads/writes exactly one Terraform state object and its
#                       lock. Created by bootstrap/aws-terraform-oidc, granted by
#                       the policy bootstrap/aws-tfstate emits. Referenced here.
#   2. INFRA DEPLOYMENT created here. Provisions the stack. Explicitly DENIED all
#                       access to the state substrate and denied any ability to
#                       mint a long-lived IAM credential.
#   3. TASK EXECUTION   pulls images and fetches secrets for ECS. Created by
#                       modules/aws-ecs. Passable by the deployment role, by name
#                       prefix, only to ecs-tasks.amazonaws.com.
#   4. APP RUNTIME      the application's own identity. Created by modules/aws-ecs.
#
# Terraform reaches (1) through the S3 backend's own `assume_role` block and (2)
# through the provider's `assume_role` block, so one run holds both without
# either role inheriting the other's permissions.
#
# This root creates no IAM user and no access key. There is no variable that
# makes it create one.
###############################################################################

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  name = "${var.name_prefix}-${var.environment}"

  tags = merge({
    ManagedBy   = "terraform"
    Purpose     = "honua-governed-execution-identity"
    Environment = var.environment
  }, var.tags)

  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  use_oidc = var.trust_mode == "oidc" || var.trust_mode == "both"
  use_sso  = var.trust_mode == "sso" || var.trust_mode == "both"

  oidc_hostpath = trimprefix(var.oidc_provider_url, "https://")

  deployment_role_arn = aws_iam_role.deployment.arn

  passable_role_arns = distinct(compact([
    "arn:${local.partition}:iam::${local.account_id}:role/${var.task_execution_role_name_prefix}*",
    "arn:${local.partition}:iam::${local.account_id}:role/${var.app_runtime_role_name_prefix}*",
  ]))

  # Roles the deployment identity must never be able to pass to a service: doing
  # so would let a task run as the deployer or as the backend reader.
  unpassable_role_arns = distinct(compact([
    local.deployment_role_arn,
    var.backend_access_role_arn,
  ]))

  state_substrate_arns = distinct(compact(concat([
    var.state_bucket_arn,
    "${var.state_bucket_arn}/*",
  ], var.state_lock_table_arn == "" ? [] : [var.state_lock_table_arn])))

  execution_identity_contract = {
    schema_version = "v1"
    kind           = "honua.iac.execution-identity"
    account = {
      account_id = local.account_id
      partition  = local.partition
      region     = var.aws_region
    }
    federation = {
      mode                 = var.trust_mode
      issuer               = local.use_oidc ? var.oidc_provider_url : null
      audience             = local.use_oidc ? var.oidc_audience : null
      subjects             = local.use_oidc ? var.oidc_subjects : []
      trusted_principals   = local.use_sso ? var.trusted_principal_arns : []
      max_session_duration = var.max_session_duration
      credential_kind      = "short-lived-sts-only"
    }
    roles = {
      backend_access = {
        purpose    = "terraform-state-and-lock-only"
        role_arn   = var.backend_access_role_arn != "" ? var.backend_access_role_arn : null
        policy_arn = var.backend_access_policy_arn != "" ? var.backend_access_policy_arn : null
        created_by = "bootstrap/aws-terraform-oidc"
      }
      infra_deployment = {
        purpose    = "provision-stack-resources"
        role_arn   = local.deployment_role_arn
        policy_arn = aws_iam_policy.deployment.arn
        created_by = "bootstrap/aws-exec-identity"
      }
      task_execution = {
        purpose            = "ecs-image-pull-and-secret-fetch"
        role_arn           = var.task_execution_role_arn != "" ? var.task_execution_role_arn : null
        role_name_prefix   = var.task_execution_role_name_prefix
        created_by         = "modules/aws-ecs"
        passable_by_deploy = true
      }
      app_runtime = {
        purpose            = "application-workload-identity"
        role_arn           = var.app_runtime_role_arn != "" ? var.app_runtime_role_arn : null
        role_name_prefix   = var.app_runtime_role_name_prefix
        created_by         = "modules/aws-ecs"
        passable_by_deploy = true
      }
    }
    separation = {
      backend_access_denied_to_deployment = true
      long_lived_credentials_denied       = true
      deployment_role_not_passable        = true
      iam_user_created                    = false
      access_key_created                  = false
    }
    evidence_scope = "non-secret-identity-references"
  }
}

check "oidc_inputs_present" {
  assert {
    condition = !local.use_oidc || (
      trimspace(var.oidc_provider_arn) != "" &&
      trimspace(var.oidc_provider_url) != "" &&
      length(var.oidc_subjects) > 0
    )
    error_message = "trust_mode includes oidc, so oidc_provider_arn, oidc_provider_url and at least one oidc_subject are required."
  }
}

check "sso_inputs_present" {
  assert {
    condition     = !local.use_sso || length(var.trusted_principal_arns) > 0
    error_message = "trust_mode includes sso, so at least one trusted principal ARN is required."
  }
}

check "roles_are_distinct" {
  assert {
    condition = alltrue([
      for arn in compact([
        var.backend_access_role_arn,
        var.task_execution_role_arn,
        var.app_runtime_role_arn,
      ]) : arn != local.deployment_role_arn
    ])
    error_message = "The deployment role must be distinct from the backend, task execution, and application runtime roles."
  }
}

check "backend_and_runtime_roles_are_distinct" {
  assert {
    condition = length(compact([
      var.backend_access_role_arn,
      var.task_execution_role_arn,
      var.app_runtime_role_arn,
      ])) == length(distinct(compact([
        var.backend_access_role_arn,
        var.task_execution_role_arn,
        var.app_runtime_role_arn,
    ])))
    error_message = "The backend, task execution, and application runtime roles must be three different roles."
  }
}

# ---------------------------------------------------------------------------
# Trust policy. Web identity, already-federated principals, or both. Never a
# long-lived IAM user.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deployment_trust" {
  dynamic "statement" {
    for_each = local.use_oidc ? [1] : []

    content {
      sid     = "WebIdentityFederation"
      effect  = "Allow"
      actions = ["sts:AssumeRoleWithWebIdentity"]

      principals {
        type        = "Federated"
        identifiers = [var.oidc_provider_arn]
      }

      condition {
        test     = "StringEquals"
        variable = "${local.oidc_hostpath}:aud"
        values   = [var.oidc_audience]
      }

      condition {
        test     = "StringLike"
        variable = "${local.oidc_hostpath}:sub"
        values   = var.oidc_subjects
      }
    }
  }

  dynamic "statement" {
    for_each = local.use_sso ? [1] : []

    content {
      sid     = "FederatedPrincipalAssumeRole"
      effect  = "Allow"
      actions = ["sts:AssumeRole", "sts:TagSession"]

      principals {
        type        = "AWS"
        identifiers = var.trusted_principal_arns
      }
    }
  }
}

resource "aws_iam_role" "deployment" {
  name                 = "${local.name}-deploy"
  description          = "Honua infrastructure deployment role. Short-lived STS sessions only."
  assume_role_policy   = data.aws_iam_policy_document.deployment_trust.json
  max_session_duration = var.max_session_duration
  tags                 = local.tags
}

# ---------------------------------------------------------------------------
# Deployment permissions. Region-scoped allows, plus the three denials that keep
# this role inside its lane: no state substrate, no long-lived credentials, no
# passing the privileged roles.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deployment" {
  #checkov:skip=CKV_AWS_356: Several provisioning APIs (ec2/elb/ecs describe, tag) have no resource-level scoping; the region condition plus explicit denials bound them.
  #checkov:skip=CKV_AWS_110: Provisioning inherently needs create/delete across the stack's services.
  #checkov:skip=CKV_AWS_111: Write access is required to provision; PassRole is separately constrained.
  #checkov:skip=CKV_AWS_107: Secret creation is required to provision the stack's managed secrets.
  #checkov:skip=CKV_AWS_108: Networking and logging actions are required to provision the stack.
  #checkov:skip=CKV_AWS_109: Role management is required for the task roles; user/key management is explicitly denied.
  statement {
    sid    = "ProvisionStackResources"
    effect = "Allow"
    actions = [
      "acm:AddTagsToCertificate",
      "acm:DeleteCertificate",
      "acm:DescribeCertificate",
      "acm:ListCertificates",
      "acm:RemoveTagsFromCertificate",
      "acm:RequestCertificate",
      "application-autoscaling:DeleteScalingPolicy",
      "application-autoscaling:DeregisterScalableTarget",
      "application-autoscaling:Describe*",
      "application-autoscaling:ListTagsForResource",
      "application-autoscaling:PutScalingPolicy",
      "application-autoscaling:RegisterScalableTarget",
      "application-autoscaling:TagResource",
      "application-autoscaling:UntagResource",
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
      "ec2:ReleaseAddress",
      "ec2:ReplaceRoute",
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
      "route53:ChangeResourceRecordSets",
      "route53:GetChange",
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:DeleteObject",
      "s3:Get*",
      "s3:List*",
      "s3:PutBucket*",
      "s3:PutEncryptionConfiguration",
      "s3:PutObject",
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
      "wafv2:AssociateWebACL",
      "wafv2:CreateWebACL",
      "wafv2:DeleteWebACL",
      "wafv2:DisassociateWebACL",
      "wafv2:GetWebACL",
      "wafv2:ListWebACLs",
      "wafv2:TagResource",
      "wafv2:UntagResource",
      "wafv2:UpdateWebACL",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid    = "ManageWorkloadRoles"
    effect = "Allow"
    actions = [
      "iam:AttachRolePolicy",
      "iam:CreatePolicy",
      "iam:CreatePolicyVersion",
      "iam:CreateRole",
      "iam:CreateServiceLinkedRole",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListPolicyVersions",
      "iam:ListRolePolicies",
      "iam:ListRoles",
      "iam:PutRolePolicy",
      "iam:TagPolicy",
      "iam:TagRole",
      "iam:UntagPolicy",
      "iam:UntagRole",
    ]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role/${var.name_prefix}*",
      "arn:${local.partition}:iam::${local.account_id}:policy/${var.name_prefix}*",
    ]
  }

  statement {
    sid    = "PassWorkloadRolesToEcsOnly"
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = local.passable_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # --- separation denials --------------------------------------------------

  # The state substrate belongs to the BACKEND role. A deployment session that
  # could write state directly could rewrite lineage under an approved plan.
  statement {
    sid    = "DenyStateSubstrateAccess"
    effect = "Deny"
    actions = [
      "dynamodb:DeleteItem",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
    ]
    resources = local.state_substrate_arns
  }

  # Nothing on the certified path may create a credential that outlives the
  # session that created it.
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

  # No privilege loop: the deployment role cannot hand its own identity, or the
  # backend reader's, to a running task.
  statement {
    sid    = "DenyPassingPrivilegedRoles"
    effect = "Deny"
    actions = [
      "iam:PassRole",
    ]
    resources = local.unpassable_role_arns
  }
}

resource "aws_iam_policy" "deployment" {
  name        = "${local.name}-deploy"
  description = "Least-privilege Honua infrastructure deployment permissions with state-substrate and long-lived-credential denials."
  policy      = data.aws_iam_policy_document.deployment.json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "deployment" {
  role       = aws_iam_role.deployment.name
  policy_arn = aws_iam_policy.deployment.arn
}
