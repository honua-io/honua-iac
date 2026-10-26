###############################################################################
# GitHub Actions -> AWS OIDC federation (honua-iac#2164)
#
# First AWS OIDC provider in this repo. A dispatched GitHub Actions cert
# workflow assumes the role below via aws-actions/configure-aws-credentials —
# no long-lived IAM access key. The trust policy pins:
#   - issuer  = token.actions.githubusercontent.com (the OIDC provider)
#   - aud     = sts.amazonaws.com
#   - sub     = repo:<owner>/<repo>:ref:refs/heads/trunk by default, or
#               repo:<owner>/<repo>:environment:<name>, or the explicit
#               subjects override -- always matched with StringEquals
# and the permission policy is scoped by Resource/Condition to the
# honua-cert-* certification surface (Batch submit against the STANDING pool +
# job-definition register/deregister/tag scoped to a DISJOINT run-only namespace
# + describe/terminate, ECS, Lambda invoke/alias/version management, the cert S3
# bucket incl. object tagging, CloudWatch read, and iam:PassRole for ONLY the
# ECS/ALB cutover execution role). The submit and register scopes are kept
# disjoint so the role cannot compose register(role-carrying)+submit into
# arbitrary-code-as-GP-role; the GP job/execution roles are NOT passable here.
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

  # Exact trust `sub` values (StringEquals). Explicit subjects win; otherwise
  # pin to one GitHub Environment when named, else to one ref (default trunk).
  # A job that declares an environment presents the environment subject, not
  # the ref subject.
  oidc_subjects = length(var.github_oidc_subjects) > 0 ? var.github_oidc_subjects : [
    var.github_oidc_environment != "" ? "repo:${var.github_owner}/${var.github_repository}:environment:${var.github_oidc_environment}" : "repo:${var.github_owner}/${var.github_repository}:ref:${var.github_oidc_ref}"
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
# provider, the sts.amazonaws.com audience, and the exact repo/ref or
# repo/environment `sub` values.
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
      test     = "StringEquals"
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
  # Submit GP Batch jobs against the STANDING pool. SubmitJob requires BOTH the
  # job-queue and the job-definition resource types, scoped to the standing
  # honua-cert-cert-* pool (resource_name_prefix = <name_prefix>-<environment>).
  # This is intentionally the STANDING-pool prefix: the execution cell submits the
  # preconfigured gp-s job definition, which already carries the GP job/execution
  # roles baked in by terraform. It is a DIFFERENT (and disjoint) prefix from the
  # register/deregister grant below — an attacker holding this role can submit the
  # standing definitions but cannot register or modify them, and cannot submit the
  # ephemeral definitions it is allowed to register (they live in another namespace).
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

  # Register / deregister and (un)tag the EPHEMERAL per-run job definitions the
  # cert tests mint. This is the attacker-relevant statement, so it is scoped to a
  # DISTINCT run-only namespace (jobdef_lifecycle_name_prefix = "honua-certrun")
  # that is DISJOINT from the standing submittable pool (resource_name_prefix =
  # honua-cert-cert-*): the register smoke names its definition honua-certrun-<runid>-*
  # and tags it honua-cert-run=<id> for per-run cleanup. Because this namespace is
  # NOT reachable by SubmitJob (above) and the standing pool is NOT reachable by
  # Register/Deregister (here), the role cannot compose Register(role-carrying)+Submit
  # into arbitrary-code-as-GP-role, and cannot DeregisterJobDefinition the standing pool.
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
      "${local.batch_arn_prefix}:job-definition/${coalesce(var.jobdef_lifecycle_name_prefix != "" ? var.jobdef_lifecycle_name_prefix : null, var.resource_name_prefix)}-*"
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

  #checkov:skip=CKV_AWS_356: Batch/ECS/ELBv2 describe + CloudWatch read actions do not support resource-level ARNs; scoped by account/region.
  statement {
    sid    = "BatchEcsElbDescribe"
    effect = "Allow"
    actions = [
      "batch:DescribeJobs",
      "batch:ListJobs",
      "batch:DescribeJobQueues",
      "batch:DescribeJobDefinitions",
      "batch:DescribeComputeEnvironments",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:DescribeTaskDefinition",
      # ECS/ALB weighted-cutover cell: read service + ELBv2 listener/rule/target
      # state to drive and verify the cutover. These describe actions do not
      # support resource-level ARNs.
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth"
    ]
    resources = ["*"]
  }

  # ECS/ALB weighted-cutover cell: read + update the cert service so the backend
  # can trigger a deployment and observe convergence. Scoped to the honua-cert-*
  # service surface (IAM `*` spans the cluster/service ARN segments).
  statement {
    sid    = "EcsCertServiceManageScoped"
    effect = "Allow"
    actions = [
      "ecs:DescribeServices",
      "ecs:UpdateService"
    ]
    resources = [
      "arn:aws:ecs:${local.region}:${local.account_id}:service/${var.resource_name_prefix}-*"
    ]
  }

  # ECS/ALB weighted-cutover cell: rewrite the listener's weighted default rule
  # (and restore it on rollback). Scoped to the exact listener + listener-rule
  # ARNs the cert stack passes; empty input grants nothing (optional-grant).
  dynamic "statement" {
    for_each = length(var.cert_alb_modify_resource_arns) > 0 ? [1] : []
    content {
      sid    = "AlbWeightedCutoverModifyScoped"
      effect = "Allow"
      actions = [
        "elasticloadbalancing:ModifyRule",
        "elasticloadbalancing:ModifyListener"
      ]
      resources = var.cert_alb_modify_resource_arns
    }
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

  # PassRole scoped to the supplied role ARNs and condition-locked to the
  # batch/ecs-tasks services that consume them. In the cert stack the ONLY ARN
  # supplied is the ECS/ALB cutover execution role (ecs:UpdateService requires
  # iam:PassRole for the task definition's execution role). The GP job/execution
  # roles are deliberately NOT supplied: SubmitJob against the standing pool rides
  # the roles terraform baked into those definitions at register time, and the cert
  # tests never register a role-carrying definition, so no PassRole of the GP roles
  # is needed — and granting it would reopen the register(role-carrying)+submit
  # escalation. Empty input grants nothing (optional-grant).
  dynamic "statement" {
    for_each = length(var.batch_job_role_arns) > 0 ? [1] : []
    content {
      sid       = "PassCertJobRoles"
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

# ---------------------------------------------------------------------------
# Optional: honua-iac hosted-pilot foundation bootstrap executor
# (.github/workflows/hosted-pilot-bootstrap.yml, job `bootstrap`). Replaces the
# static AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY repository secrets with a
# short-lived web-identity session. Disabled by default.
#
# GitHub puts either the environment or the ref in `sub`, never both, and the
# job runs in the terraform-ephemeral environment, so the trust pins the exact
# repo + environment subject. The trunk-only half of the pin is enforced by the
# workflow's own `github.ref == 'refs/heads/trunk'` guard and must also be set
# as the environment's deployment-branch policy (trunk only).
#
# This component does not invent the executor's permissions: the operator
# attaches the reviewed policy the static-key principal held today.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "hosted_pilot_bootstrap_trust" {
  count = var.hosted_pilot_bootstrap_role_enabled ? 1 : 0

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
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.hosted_pilot_bootstrap_oidc_subjects
    }
  }
}

resource "aws_iam_role" "hosted_pilot_bootstrap" {
  count = var.hosted_pilot_bootstrap_role_enabled ? 1 : 0

  name                 = var.hosted_pilot_bootstrap_role_name
  description          = "Short-lived OIDC executor for honua-iac hosted-pilot-bootstrap.yml (terraform-ephemeral, trunk)."
  assume_role_policy   = data.aws_iam_policy_document.hosted_pilot_bootstrap_trust[0].json
  max_session_duration = var.hosted_pilot_bootstrap_max_session_duration_seconds
  permissions_boundary = var.hosted_pilot_bootstrap_permissions_boundary_arn != "" ? var.hosted_pilot_bootstrap_permissions_boundary_arn : null
  tags                 = merge(local.tags, { Purpose = "hosted-pilot-foundation-bootstrap" })

  lifecycle {
    precondition {
      condition     = length(var.hosted_pilot_bootstrap_policy_arns) > 0
      error_message = "hosted_pilot_bootstrap_policy_arns must name the reviewed executor policy when hosted_pilot_bootstrap_role_enabled = true."
    }
  }
}

resource "aws_iam_role_policy_attachment" "hosted_pilot_bootstrap" {
  for_each = var.hosted_pilot_bootstrap_role_enabled ? toset(var.hosted_pilot_bootstrap_policy_arns) : toset([])

  role       = aws_iam_role.hosted_pilot_bootstrap[0].name
  policy_arn = each.value
}
