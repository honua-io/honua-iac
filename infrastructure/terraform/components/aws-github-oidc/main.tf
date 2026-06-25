###############################################################################
# GitHub Actions -> AWS OIDC federation (honua-iac#2164)
#
# First AWS OIDC provider in this repo. A dispatched GitHub Actions cert
# workflow assumes the role below via aws-actions/configure-aws-credentials —
# no long-lived IAM access key. The trust policy pins:
#   - issuer  = token.actions.githubusercontent.com (the OIDC provider)
#   - aud     = sts.amazonaws.com
#   - sub     = repo:<owner>/<repo>:* (or the explicit subjects override)
# and the permission policy is scoped by Resource/Condition to the
# honua-cert-* certification surface (Batch submit/describe/terminate, ECS,
# Lambda invoke, the cert S3 bucket, CloudWatch read, and iam:PassRole for the
# GP job roles).
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name = "${var.name_prefix}-${var.environment}"
  tags = merge({
    Project     = "honua-server"
    Environment = var.environment
    ManagedBy   = "terraform"
    Purpose     = var.purpose
  }, var.tags)

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn

  # Trust `sub` patterns. Explicit subjects win; otherwise scope to the repo.
  oidc_subjects = length(var.github_oidc_subjects) > 0 ? var.github_oidc_subjects : [
    "repo:${var.github_owner}/${var.github_repository}:*"
  ]

  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # honua-cert-* ARN wildcards the cert workflow operates within.
  batch_arn_prefix     = "arn:aws:batch:${local.region}:${local.account_id}"
  cert_log_group_arn   = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/batch/${var.resource_name_prefix}-*"
  cert_lambda_arn_glob = "arn:aws:lambda:${local.region}:${local.account_id}:function:${var.resource_name_prefix}-*"
  invoke_function_arns = concat([local.cert_lambda_arn_glob], var.extra_invoke_function_arns)
}

check "existing_provider_when_not_creating" {
  assert {
    condition     = var.create_oidc_provider || trimspace(var.existing_oidc_provider_arn) != ""
    error_message = "existing_oidc_provider_arn is required when create_oidc_provider = false."
  }
}

# ---------------------------------------------------------------------------
# OIDC provider for GitHub Actions.
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = [var.oidc_audience]
  thumbprint_list = var.github_oidc_thumbprints

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Assume-role trust policy — web identity federation scoped to the OIDC
# provider, the sts.amazonaws.com audience, and the repo/ref `sub` patterns.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = [var.oidc_audience]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.oidc_subjects
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = "${local.name}-gha"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_duration_seconds
  tags                 = local.tags
}

# ---------------------------------------------------------------------------
# Permission policy — least-privilege, scoped to the honua-cert-* surface.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "permissions" {
  # Submit / observe / terminate GP Batch jobs. Submit/terminate scope to the
  # cert queue + job definitions; describe/list have no resource-level scoping.
  statement {
    sid    = "BatchSubmitTerminateScoped"
    effect = "Allow"
    actions = [
      "batch:SubmitJob",
      "batch:TerminateJob",
      "batch:CancelJob"
    ]
    resources = [
      "${local.batch_arn_prefix}:job-queue/${var.resource_name_prefix}-*",
      "${local.batch_arn_prefix}:job-definition/${var.resource_name_prefix}-*"
    ]
  }

  #checkov:skip=CKV_AWS_356: Batch/ECS describe + CloudWatch read actions do not support resource-level ARNs; scoped by account/region.
  statement {
    sid    = "BatchEcsDescribe"
    effect = "Allow"
    actions = [
      "batch:DescribeJobs",
      "batch:ListJobs",
      "batch:DescribeJobQueues",
      "batch:DescribeJobDefinitions",
      "batch:DescribeComputeEnvironments",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:DescribeTaskDefinition"
    ]
    resources = ["*"]
  }

  # Invoke cert Lambda(s) — e.g. a certification driver / demo flip target.
  dynamic "statement" {
    for_each = length(local.invoke_function_arns) > 0 ? [1] : []
    content {
      sid       = "LambdaInvokeScoped"
      effect    = "Allow"
      actions   = ["lambda:InvokeFunction"]
      resources = local.invoke_function_arns
    }
  }

  # Read/write the cert artifact bucket.
  dynamic "statement" {
    for_each = trimspace(var.cert_artifact_bucket_arn) != "" ? [1] : []
    content {
      sid    = "CertBucketObjects"
      effect = "Allow"
      actions = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ]
      resources = ["${var.cert_artifact_bucket_arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = trimspace(var.cert_artifact_bucket_arn) != "" ? [1] : []
    content {
      sid       = "CertBucketList"
      effect    = "Allow"
      actions   = ["s3:ListBucket"]
      resources = [var.cert_artifact_bucket_arn]
    }
  }

  # CloudWatch Logs read — pull GP job logs for certification evidence.
  statement {
    sid    = "CloudWatchLogsReadScoped"
    effect = "Allow"
    actions = [
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:DescribeLogStreams"
    ]
    resources = [
      local.cert_log_group_arn,
      "${local.cert_log_group_arn}:*"
    ]
  }

  #checkov:skip=CKV_AWS_356: CloudWatch DescribeLogGroups / metric reads do not support resource-level ARNs.
  statement {
    sid    = "CloudWatchReadGlobal"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics"
    ]
    resources = ["*"]
  }

  # PassRole for the GP job roles so the workflow can submit Batch jobs that
  # carry them; scoped to the supplied role ARNs and the consuming services.
  dynamic "statement" {
    for_each = length(var.batch_job_role_arns) > 0 ? [1] : []
    content {
      sid       = "PassGpJobRoles"
      effect    = "Allow"
      actions   = ["iam:PassRole"]
      resources = var.batch_job_role_arns

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
}

resource "aws_iam_role_policy" "permissions" {
  name   = "${local.name}-cert-permissions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.permissions.json
}
