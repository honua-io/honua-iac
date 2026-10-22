# The independent retained controller identity for aws-update-rollback.yml
# (honua-release docs/AWS-UPDATE-ROLLBACK-PRODUCER.md). The producer's runner assumes
# it with session name `honua-update-rollback-controller`; the retained controller and
# the read-only candidate schema probe run with those credentials.
#
# Grants here are the standing floor only:
#   - Lambda cells: alias read/update on cell functions (honua-gitops-aws-lambda backend).
#   - CloudWatch metric reads for the `aws-cloudwatch` telemetry connection.
# ECS cells add their own exact, per-cell grant: examples/aws `deployment_safety`
# attaches `<cell>-recovery` (ecs:UpdateService on the canary service, ModifyRule on the
# protected listener rule) to this role and removes it on destroy.
data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  lambda_function_arns = flatten([for prefix in var.lambda_function_prefixes : [
    "arn:aws:lambda:${var.region}:${local.account_id}:function:${prefix}*",
    "arn:aws:lambda:${var.region}:${local.account_id}:function:${prefix}*:*",
  ]])
}

# Permissions ceiling. honua-release-cicd may put/delete inline policies on this role (the ECS
# cells attach their per-cell recovery grant), so without a boundary it could grant itself
# anything here and assume it. The boundary caps every inline grant at the controller's job.
resource "aws_iam_policy" "boundary" {
  name        = "${var.name}-boundary"
  description = "Ceiling for the update/rollback controller role: ECS/ALB rollout, Lambda alias switch, CloudWatch reads."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EcsAlbRollout"
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices", "ecs:UpdateService", "ecs:DescribeTaskDefinition", "ecs:DescribeTasks", "ecs:ListTasks",
          "elasticloadbalancing:ModifyRule", "elasticloadbalancing:DescribeRules", "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeListeners",
        ]
        Resource = "*"
      },
      {
        Sid    = "CellLambdaAliasSwitch"
        Effect = "Allow"
        Action = [
          "lambda:GetAlias", "lambda:UpdateAlias", "lambda:GetFunction", "lambda:GetFunctionConfiguration",
          "lambda:ListVersionsByFunction", "lambda:ListAliases",
        ]
        Resource = local.lambda_function_arns
      },
      {
        Sid      = "CloudWatchTelemetryRead"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:ListMetrics"]
        Resource = "*"
      },
      {
        Sid       = "NeverStandingResources"
        Effect    = "Deny"
        Action    = "*"
        Resource  = "*"
        Condition = { StringEquals = { "aws:ResourceTag/Environment" = ["cert", "demo"] } }
      },
    ]
  })
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
  name = "${var.name}-floor"
  role = aws_iam_role.controller.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CellLambdaAliasSwitch"
        Effect = "Allow"
        Action = [
          "lambda:GetAlias",
          "lambda:UpdateAlias",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:ListVersionsByFunction",
          "lambda:ListAliases",
        ]
        Resource = local.lambda_function_arns
      },
      {
        # CloudWatch metric reads do not support resource-level permissions.
        Sid      = "CloudWatchTelemetryRead"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:ListMetrics"]
        Resource = "*"
      },
      {
        Sid       = "CertificationRegionOnly"
        Effect    = "Deny"
        Action    = "*"
        Resource  = "*"
        Condition = { StringNotEquals = { "aws:RequestedRegion" = var.region } }
      },
    ]
  })
}
