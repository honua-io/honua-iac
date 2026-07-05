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
# honua-cert-* certification surface (Batch submit + job-definition
# register/deregister/tag + describe/terminate, ECS, Lambda invoke/alias/version
# management, the cert S3 bucket incl. object tagging, CloudWatch read, and
# iam:PassRole for the GP job + execution roles).
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
  # Submit GP Batch jobs. SubmitJob requires BOTH the job-queue and the
  # job-definition resource types, scoped to the honua-cert-* pool.
  statement {
    sid    = "BatchSubmitScoped"
    effect = "Allow"
    actions = [
      "batch:SubmitJob"
    ]
    resources = [
      "${local.batch_arn_prefix}:job-queue/${var.resource_name_prefix}-*",
      "${local.batch_arn_prefix}:job-definition/${var.resource_name_prefix}-*"
    ]
  }

  # Register / deregister and (un)tag the ephemeral per-run job definitions the
  # cert tests mint. Scoped to the honua-cert-* job-definition surface — the
  # tests name their job definitions under this prefix so SubmitJob (above) can
  # reach them, and tag them with honua-cert-run=<id> for per-run cleanup.
  statement {
    sid    = "BatchJobDefinitionLifecycleScoped"
    effect = "Allow"
    actions = [
      "batch:RegisterJobDefinition",
      "batch:DeregisterJobDefinition",
      "batch:TagResource",
      "batch:UntagResource"
    ]
    resources = [
      "${local.batch_arn_prefix}:job-definition/${var.resource_name_prefix}-*"
    ]
  }

  # Terminate / cancel in-flight jobs. Batch job ARNs carry a server-assigned
  # UUID that cannot be name-prefixed (TerminateJob's resource type is `job`,
  # not job-definition), so scope to the account/region job namespace — still
  # far narrower than "*" and confined to this account+region.
  statement {
    sid    = "BatchJobTerminateScoped"
    effect = "Allow"
    actions = [
      "batch:TerminateJob",
      "batch:CancelJob"
    ]
    resources = [
      "${local.batch_arn_prefix}:job/*"
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

  # Invoke + manage cert Lambda(s). Invoke drives the certification flow; the
  # get/alias/version actions let the cert tests publish a version and flip the
  # served alias (blue/green) then read the function + alias state back. Scoped
  # to the honua-cert-* function surface.
  dynamic "statement" {
    for_each = length(local.invoke_function_arns) > 0 ? [1] : []
    content {
      sid    = "LambdaInvokeAndManageScoped"
      effect = "Allow"
      actions = [
        "lambda:InvokeFunction",
        "lambda:GetFunction",
        "lambda:GetAlias",
        "lambda:UpdateAlias",
        "lambda:PublishVersion"
      ]
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
        "s3:DeleteObject",
        # Per-run artifact identification: stamp honua-cert-run=<id> on objects
        # and read the tag back for verification/cleanup.
        "s3:PutObjectTagging",
        "s3:GetObjectTagging"
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

  # PassRole for the GP job + execution roles so the workflow can submit Batch
  # jobs that carry them; scoped to the supplied role ARNs and condition-locked
  # to the batch/ecs-tasks services that consume them.
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
