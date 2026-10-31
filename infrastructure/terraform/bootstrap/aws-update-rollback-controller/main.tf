# The independent retained controller identity for aws-update-rollback.yml
# (honua-release docs/AWS-UPDATE-ROLLBACK-PRODUCER.md). The producer's runner assumes
# it with session name `honua-update-rollback-controller`; the retained controller and
# the read-only candidate schema probe run with those credentials.
#
# Grants here are the standing floor only:
#   - Lambda cells: alias read/update on cell functions (honua-gitops-aws-lambda backend).
#   - CloudWatch metric reads for the `aws-cloudwatch` telemetry connection.
#   - Restore, when restore_name_prefixes is non-empty: RDS snapshot restore, secret host
#     retarget, and the KMS calls an encrypted restore needs, only on those prefixes.
# ECS cells add their own exact, per-cell grant: examples/aws `deployment_safety`
# attaches `<cell>-recovery` (ecs:UpdateService on the canary service, ModifyRule on the
# protected listener rule) to this role and removes it on destroy. This root does not add
# a floor ecs:UpdateService on every prefixed service.
data "aws_caller_identity" "current" {}

locals {
  account_id           = data.aws_caller_identity.current.account_id
  has_restore          = length(var.restore_name_prefixes) > 0
  lambda_name_prefixes = distinct(concat(var.lambda_function_prefixes, var.restore_name_prefixes))
  lambda_function_arns = flatten([for prefix in local.lambda_name_prefixes : [
    "arn:aws:lambda:${var.region}:${local.account_id}:function:${prefix}*",
    "arn:aws:lambda:${var.region}:${local.account_id}:function:${prefix}*:*",
  ]])
  restore_arns = flatten([for prefix in var.restore_name_prefixes : [
    "arn:aws:rds:${var.region}:${local.account_id}:db:${prefix}*",
    "arn:aws:rds:${var.region}:${local.account_id}:snapshot:${prefix}*",
    "arn:aws:rds:${var.region}:${local.account_id}:snapshot:rds:${prefix}*",
    "arn:aws:rds:${var.region}:${local.account_id}:subgrp:${prefix}*",
    "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:${prefix}*",
    "arn:aws:ecs:${var.region}:${local.account_id}:service/${prefix}*",
    "arn:aws:ecs:${var.region}:${local.account_id}:task-definition/${prefix}*",
    "arn:aws:lambda:${var.region}:${local.account_id}:function:${prefix}*",
    "arn:aws:lambda:${var.region}:${local.account_id}:function:${prefix}*:*",
    "arn:aws:elasticloadbalancing:${var.region}:${local.account_id}:listener-rule/app/${prefix}*",
  ]])
  secret_arns = [for prefix in var.restore_name_prefixes : "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:${prefix}*"]
}

data "aws_iam_policy_document" "boundary" {
  statement {
    sid = "EcsAlbRollout"
    actions = [
      "ecs:DescribeServices", "ecs:UpdateService", "ecs:DescribeTaskDefinition", "ecs:DescribeTasks", "ecs:ListTasks",
      "elasticloadbalancing:ModifyRule", "elasticloadbalancing:DescribeRules", "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeListeners",
    ]
    resources = ["*"]
  }

  statement {
    sid = "CellLambdaAliasSwitch"
    actions = [
      "lambda:GetAlias", "lambda:UpdateAlias", "lambda:GetFunction", "lambda:GetFunctionConfiguration",
      "lambda:ListVersionsByFunction", "lambda:ListAliases",
    ]
    resources = local.lambda_function_arns
  }

  statement {
    sid       = "CloudWatchTelemetryRead"
    actions   = ["cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:ListMetrics"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = local.has_restore ? [1] : []
    content {
      sid = "CellRestore"
      actions = [
        "rds:RestoreDBInstanceFromDBSnapshot",
        "rds:DescribeDBSnapshots",
        "rds:DescribeDBInstances",
        "rds:ListTagsForResource",
        "rds:AddTagsToResource",
      ]
      resources = local.restore_arns
    }
  }

  dynamic "statement" {
    for_each = local.has_restore ? [1] : []
    content {
      sid = "CellConnectionSecret"
      actions = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      resources = local.secret_arns
    }
  }

  dynamic "statement" {
    for_each = local.has_restore ? [1] : []
    content {
      sid       = "CellRestoreKmsViaRds"
      actions   = ["kms:Decrypt", "kms:CreateGrant", "kms:DescribeKey"]
      resources = ["*"]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["rds.${var.region}.amazonaws.com"]
      }
    }
  }

  statement {
    sid    = "NoCellDestruction"
    effect = "Deny"
    actions = [
      "rds:DeleteDBInstance",
      "rds:DeleteDBSnapshot",
      "rds:DeleteDBCluster",
      "rds:ModifyDBInstance",
      "secretsmanager:DeleteSecret",
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = local.has_restore ? [] : [1]
    content {
      sid       = "NeverStandingResources"
      effect    = "Deny"
      actions   = ["*"]
      resources = ["*"]
      condition {
        test     = "StringEquals"
        variable = "aws:ResourceTag/Environment"
        values   = ["cert", "demo"]
      }
    }
  }

  dynamic "statement" {
    for_each = local.has_restore ? [1] : []
    content {
      sid           = "NeverStandingResources"
      effect        = "Deny"
      actions       = ["*"]
      not_resources = local.restore_arns
      condition {
        test     = "StringEquals"
        variable = "aws:ResourceTag/Environment"
        values   = ["cert", "demo"]
      }
    }
  }
}

data "aws_iam_policy_document" "floor" {
  statement {
    sid = "CellLambdaAliasSwitch"
    actions = [
      "lambda:GetAlias",
      "lambda:UpdateAlias",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:ListVersionsByFunction",
      "lambda:ListAliases",
    ]
    resources = local.lambda_function_arns
  }

  statement {
    # CloudWatch metric reads do not support resource-level permissions.
    sid       = "CloudWatchTelemetryRead"
    actions   = ["cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:ListMetrics"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = local.has_restore ? [1] : []
    content {
      sid = "CellRestore"
      actions = [
        "rds:RestoreDBInstanceFromDBSnapshot",
        "rds:DescribeDBSnapshots",
        "rds:DescribeDBInstances",
        "rds:ListTagsForResource",
        "rds:AddTagsToResource",
      ]
      resources = local.restore_arns
    }
  }

  dynamic "statement" {
    for_each = local.has_restore ? [1] : []
    content {
      sid = "CellConnectionSecret"
      actions = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      resources = local.secret_arns
    }
  }

  dynamic "statement" {
    for_each = local.has_restore ? [1] : []
    content {
      sid       = "CellRestoreKmsViaRds"
      actions   = ["kms:Decrypt", "kms:CreateGrant", "kms:DescribeKey"]
      resources = ["*"]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["rds.${var.region}.amazonaws.com"]
      }
    }
  }

  statement {
    sid    = "NoCellDestruction"
    effect = "Deny"
    actions = [
      "rds:DeleteDBInstance",
      "rds:DeleteDBSnapshot",
      "rds:DeleteDBCluster",
      "rds:ModifyDBInstance",
      "secretsmanager:DeleteSecret",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "CertificationRegionOnly"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
}

# Permissions ceiling. honua-release-cicd may put/delete inline policies on this role (the ECS
# cells attach their per-cell recovery grant), so without a boundary it could grant itself
# anything here and assume it. The boundary caps every inline grant at the controller's job.
# A non-empty restore prefix opens the cert/demo deny only for that prefix. An empty list
# keeps the blanket deny and grants no restore.
resource "aws_iam_policy" "boundary" {
  name        = "${var.name}-boundary"
  description = "Ceiling for the update/rollback controller role: ECS/ALB rollout, Lambda alias switch, CloudWatch reads, and prefix-scoped restore."
  policy      = data.aws_iam_policy_document.boundary.json
  tags = {
    Owner     = "release-standing"
    Lifecycle = "standing"
    Purpose   = "update-rollback-controller"
  }
}

resource "aws_iam_role" "controller" {
  name                 = var.name
  permissions_boundary = aws_iam_policy.boundary.arn
  description          = "Independent retained controller for the AWS update/rollback proof (honua-release aws-update-rollback.yml)."
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ProducerRunnerOnly"
      Effect    = "Allow"
      Principal = { AWS = var.assuming_role_arn }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "sts:RoleSessionName" = var.session_name } }
    }]
  })
  tags = {
    Owner     = "release-standing"
    Lifecycle = "standing"
    Purpose   = "update-rollback-controller"
  }
}

resource "aws_iam_role_policy" "controller_floor" {
  name   = "${var.name}-floor"
  role   = aws_iam_role.controller.id
  policy = data.aws_iam_policy_document.floor.json
}
