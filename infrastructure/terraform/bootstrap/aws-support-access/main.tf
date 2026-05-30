locals {
  observe_role_name     = "${var.name_prefix}SupportObserveRole"
  break_glass_role_name = "${var.name_prefix}SupportBreakGlassRole"
}

# ---------------------------------------------------------------------------
# Trust policies (who may assume the roles, and under what guardrails)
# ---------------------------------------------------------------------------
# Both roles are assumed cross-account by Honua support principals. There are
# no IAM users and no long-lived access keys: access is always a short-lived
# STS session gated by an ExternalId (confused-deputy guard) and, optionally,
# MFA and ticket/operator session tags for auditability.

data "aws_iam_policy_document" "observe_trust" {
  statement {
    sid     = "HonuaSupportObserveAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.support_principal_arns
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.external_id]
    }
  }

  dynamic "statement" {
    for_each = var.require_session_tags ? [1] : []
    content {
      sid     = "HonuaSupportObserveSessionTags"
      effect  = "Allow"
      actions = ["sts:TagSession"]

      principals {
        type        = "AWS"
        identifiers = var.support_principal_arns
      }

      condition {
        test     = "StringLike"
        variable = "aws:RequestTag/HonuaTicketId"
        values   = ["*"]
      }

      condition {
        test     = "StringLike"
        variable = "aws:RequestTag/HonuaOperator"
        values   = ["*"]
      }
    }
  }
}

data "aws_iam_policy_document" "break_glass_trust" {
  statement {
    sid     = "HonuaSupportBreakGlassAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.support_principal_arns
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.external_id]
    }

    dynamic "condition" {
      for_each = var.require_mfa ? [1] : []
      content {
        test     = "Bool"
        variable = "aws:MultiFactorAuthPresent"
        values   = ["true"]
      }
    }

    # Break-glass sessions must carry a ticket id so every mutation is
    # traceable to an approved incident.
    dynamic "condition" {
      for_each = var.require_session_tags ? [1] : []
      content {
        test     = "StringLike"
        variable = "aws:RequestTag/HonuaTicketId"
        values   = ["*"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.require_session_tags ? [1] : []
    content {
      sid     = "HonuaSupportBreakGlassSessionTags"
      effect  = "Allow"
      actions = ["sts:TagSession"]

      principals {
        type        = "AWS"
        identifiers = var.support_principal_arns
      }

      condition {
        test     = "StringLike"
        variable = "aws:RequestTag/HonuaTicketId"
        values   = ["*"]
      }

      condition {
        test     = "StringLike"
        variable = "aws:RequestTag/HonuaOperator"
        values   = ["*"]
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Observe role: read-only diagnostics across Honua runtime targets.
# Every action is a Describe/Get/List style read. No mutations, and explicitly
# no reading of secret *values* (only secrets metadata) so diagnostics cannot
# exfiltrate credentials.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "observe" {
  statement {
    sid    = "HonuaObserveReadOnly"
    effect = "Allow"
    actions = [
      # Compute runtimes: ECS / Fargate, Lambda, EKS
      "ecs:Describe*",
      "ecs:List*",
      "lambda:Get*",
      "lambda:List*",
      "eks:Describe*",
      "eks:List*",
      "ec2:Describe*",
      "ec2:GetConsoleOutput",
      "ec2:GetConsoleScreenshot",
      "application-autoscaling:Describe*",
      "application-autoscaling:ListTagsForResource",
      "autoscaling:Describe*",

      # Data + cache: RDS, ElastiCache
      "rds:Describe*",
      "rds:ListTagsForResource",
      "elasticache:Describe*",
      "elasticache:List*",

      # Load balancing + networking inspection
      "elasticloadbalancing:Describe*",
      "wafv2:Get*",
      "wafv2:List*",

      # Telemetry: CloudWatch metrics, logs, alarms
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
      "logs:Describe*",
      "logs:Get*",
      "logs:List*",
      "logs:FilterLogEvents",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",

      # Secrets metadata only - never GetSecretValue
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecrets",
      "secretsmanager:GetResourcePolicy",
      "kms:Describe*",
      "kms:List*",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",

      # Identity + audit context
      "sts:GetCallerIdentity",
      "cloudtrail:Get*",
      "cloudtrail:Describe*",
      "cloudtrail:List*",
      "cloudtrail:LookupEvents",
      "tag:GetResources",
      "tag:GetTagKeys",
      "tag:GetTagValues",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
}

# ---------------------------------------------------------------------------
# Break-glass role: explicit, short-lived remediation. Narrower than admin:
# - no IAM/Organizations/account mutation
# - no secret value reads or writes
# - no resource deletion of stateful stores (RDS/ElastiCache delete is excluded)
# - scoped to operational "kick it" actions: restart services, roll/redeploy,
#   adjust scaling, toggle networking rules, rotate tasks, manage log retention.
# It deliberately inherits the observe permissions too so an operator does not
# have to juggle two sessions while remediating.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "break_glass" {
  source_policy_documents = [data.aws_iam_policy_document.observe.json]

  statement {
    sid    = "HonuaBreakGlassEcs"
    effect = "Allow"
    actions = [
      "ecs:UpdateService",
      "ecs:StopTask",
      "ecs:RunTask",
      "ecs:RegisterTaskDefinition",
      "ecs:DeregisterTaskDefinition",
      "ecs:TagResource",
      "ecs:UntagResource",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid    = "HonuaBreakGlassLambda"
    effect = "Allow"
    actions = [
      "lambda:UpdateFunctionConfiguration",
      "lambda:UpdateFunctionCode",
      "lambda:PublishVersion",
      "lambda:UpdateAlias",
      "lambda:InvokeFunction",
      "lambda:TagResource",
      "lambda:UntagResource",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid    = "HonuaBreakGlassEks"
    effect = "Allow"
    actions = [
      "eks:UpdateNodegroupConfig",
      "eks:UpdateClusterConfig",
      "eks:TagResource",
      "eks:UntagResource",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid    = "HonuaBreakGlassScalingAndReboot"
    effect = "Allow"
    actions = [
      # Scale services out/in to recover from saturation.
      "application-autoscaling:RegisterScalableTarget",
      "application-autoscaling:PutScalingPolicy",
      "autoscaling:SetDesiredCapacity",
      "autoscaling:UpdateAutoScalingGroup",
      # Reboot, not delete/modify, stateful stores.
      "rds:RebootDBInstance",
      "elasticache:RebootCacheCluster",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid    = "HonuaBreakGlassNetworking"
    effect = "Allow"
    actions = [
      # Adjust security-group rules to unblock or contain traffic.
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      # Re-point or drain load-balancer targets during remediation.
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid    = "HonuaBreakGlassLogsRetention"
    effect = "Allow"
    actions = [
      "logs:PutRetentionPolicy",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
}

# ---------------------------------------------------------------------------
# Permissions boundary: hard ceiling that the break-glass role can never
# exceed even if its inline policy is later widened. Denies IAM/Org/account
# escalation and secret-value reads outright.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "break_glass_boundary" {
  statement {
    sid    = "AllowScopedOperations"
    effect = "Allow"
    # Service-level ceiling for the break-glass role. The inline policy grants
    # the specific actions; this boundary caps the role to these services so it
    # can never be widened (via a future policy edit) into unrelated services.
    actions = [
      "ecs:*",
      "lambda:*",
      "eks:*",
      "ec2:*",
      "rds:*",
      "elasticache:*",
      "elasticloadbalancing:*",
      "application-autoscaling:*",
      "autoscaling:*",
      "cloudwatch:*",
      "logs:*",
      "wafv2:*",
      "secretsmanager:Describe*",
      "secretsmanager:List*",
      "secretsmanager:GetResourcePolicy",
      "kms:Describe*",
      "kms:List*",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "cloudtrail:Get*",
      "cloudtrail:Describe*",
      "cloudtrail:List*",
      "cloudtrail:LookupEvents",
      "sts:GetCallerIdentity",
      "tag:Get*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid    = "DenyPrivilegeEscalationAndSecretReads"
    effect = "Deny"
    actions = [
      "iam:*",
      "organizations:*",
      "account:*",
      "sts:AssumeRole*",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
      "secretsmanager:DeleteSecret",
      "kms:Decrypt",
      "kms:ScheduleKeyDeletion",
      "kms:DisableKey",
      "rds:DeleteDBInstance",
      "rds:DeleteDBCluster",
      "elasticache:DeleteCacheCluster",
      "elasticache:DeleteReplicationGroup",
      "ecs:DeleteCluster",
      "eks:DeleteCluster",
      "lambda:DeleteFunction",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "break_glass_boundary" {
  name        = "${local.break_glass_role_name}-boundary"
  description = "Permissions boundary capping the Honua break-glass support role below admin."
  policy      = data.aws_iam_policy_document.break_glass_boundary.json
  tags        = var.tags
}

# ---------------------------------------------------------------------------
# Roles
# ---------------------------------------------------------------------------
resource "aws_iam_role" "observe" {
  name                 = local.observe_role_name
  description          = "Read-only Honua support diagnostics role (cross-account, ExternalId-gated)."
  assume_role_policy   = data.aws_iam_policy_document.observe_trust.json
  max_session_duration = var.observe_max_session_duration
  tags                 = var.tags
}

resource "aws_iam_role_policy" "observe" {
  name   = "${local.observe_role_name}-policy"
  role   = aws_iam_role.observe.id
  policy = data.aws_iam_policy_document.observe.json
}

resource "aws_iam_role" "break_glass" {
  name                 = local.break_glass_role_name
  description          = "Short-lived elevated Honua support remediation role (cross-account, ExternalId + MFA gated)."
  assume_role_policy   = data.aws_iam_policy_document.break_glass_trust.json
  max_session_duration = var.break_glass_max_session_duration
  permissions_boundary = aws_iam_policy.break_glass_boundary.arn
  tags                 = var.tags
}

resource "aws_iam_role_policy" "break_glass" {
  name   = "${local.break_glass_role_name}-policy"
  role   = aws_iam_role.break_glass.id
  policy = data.aws_iam_policy_document.break_glass.json
}
