###############################################################################
# Honua real-AWS certification tier — examples/aws-cert (honua-iac#2164)
#
# A Honua-owned stack that certifies the serverless + GP-over-Batch path against
# REAL AWS (no LocalStack). It mirrors examples/aws-demo but is purpose-built for
# certification:
#   - reuses modules/aws-serverless with enable_gp_batch = true (the durable
#     GP substrate: a Fargate-Spot scale-to-zero compute environment, queue, and
#     a fixed POOL of job-definition size tiers; per-job sizing is a runtime
#     SubmitJob override, not a terraform re-apply);
#   - a dedicated cert S3 artifact bucket (honua-cert-* surface);
#   - GitHub-OIDC federation (components/aws-github-oidc) so the dispatched cert
#     workflow assumes a least-privilege role with NO long-lived key;
#   - an aws_budgets_budget + SNS notification cost guardrail.
#
# name_prefix="honua-cert" + environment="cert" => honua-cert-cert-* ARNs, the
# surface the OIDC role is scoped to.
#
# Serverless-everywhere / no-standing-compute: the Batch compute environment is
# Fargate-Spot scale-to-zero (nothing warm between jobs) and the cert role mints
# its credential per run via OIDC.
###############################################################################

data "aws_caller_identity" "current" {}

locals {
  name = "${var.name_prefix}-${var.environment}"

  tags = merge({
    Project     = "honua-server"
    Environment = "cert"
    ManagedBy   = "terraform"
    Purpose     = "real-aws-certification"
  }, var.tags)

  cert_artifact_bucket_name = "${local.name}-artifacts-${random_id.bucket_suffix.hex}"
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# ---------------------------------------------------------------------------
# Cert S3 artifact bucket — GP inputs/outputs + certification evidence.
# Private; reached only by the GP job role and the OIDC cert role.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "cert_artifacts" {
  #checkov:skip=CKV_AWS_18: Access logging omitted for the ephemeral certification artifact bucket; not justified for a short-lived cert environment.
  #checkov:skip=CKV_AWS_144: Cross-region replication not required; certification artifacts are reproducible and short-lived.
  #checkov:skip=CKV_AWS_145: SSE-S3 (AES-256) applied via aws_s3_bucket_server_side_encryption_configuration; a customer-managed KMS CMK is not required for cert artifacts.
  #checkov:skip=CKV2_AWS_61: Lifecycle handled by the explicit aws_s3_bucket_lifecycle_configuration below.
  #checkov:skip=CKV2_AWS_62: Event notifications not required for the certification artifact bucket.
  bucket        = local.cert_artifact_bucket_name
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "cert_artifacts" {
  bucket                  = aws_s3_bucket.cert_artifacts.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cert_artifacts" {
  bucket = aws_s3_bucket.cert_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "cert_artifacts" {
  bucket = aws_s3_bucket.cert_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Age out cert artifacts and old versions so the bucket does not accumulate cost.
resource "aws_s3_bucket_lifecycle_configuration" "cert_artifacts" {
  bucket = aws_s3_bucket.cert_artifacts.id

  rule {
    id     = "expire-cert-artifacts"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

# ---------------------------------------------------------------------------
# Honua serverless module — GP-over-Batch enabled (durable tiered substrate).
# ---------------------------------------------------------------------------

module "honua" {
  source = "../../modules/aws-serverless"

  name_prefix = var.name_prefix
  environment = var.environment

  image                = var.honua_image
  lambda_architectures = ["x86_64"]
  admin_password       = var.honua_admin_password
  db_password          = var.db_password

  # Cert is short-lived: single-AZ, modest DB, no Redis (cert does not exercise
  # the Production durable-event-store /healthz/ready path).
  db_instance_class    = "db.t4g.micro"
  db_multi_az          = false
  db_apply_immediately = true
  redis_enabled        = false

  log_retention_days = 30

  # GP over AWS Batch — DURABLE Fargate-Spot scale-to-zero substrate. The module
  # mints a fixed POOL of job-definition size tiers (gp-s/m/l/xl) that differ
  # only by ephemeral storage; per-job vCPU/memory/timeout/retry are applied at
  # runtime by the server via SubmitJob overrides, so nothing here is per-job.
  # The honua-devops gp runtime adapter consumes the exported ARNs (queue +
  # per-tier job definitions) as opaque config — it does NOT re-apply terraform
  # per job. Only substrate-level inputs (image, arch, repo) are forwarded.
  enable_gp_batch = true
  # Phase 3 custom-code egress isolation (two-phase provisioning/execution jobs +
  # CodeArtifact pull-through + locked-down execution SG) is available but OFF in
  # cert: the cert tier exercises the MVP GP-over-Batch path. Flip to true (and,
  # if git-sourced deps are needed, set customcode_github_egress_cidrs) to certify
  # the isolation path. See modules/aws-serverless docs/customcode-egress-isolation.md.
  enable_customcode_egress_isolation = false
  gp_batch_image                     = var.gp_batch_image
  gp_batch_cpu_architecture          = var.gp_batch_cpu_architecture
  gp_batch_workload_id               = var.gp_batch_workload_id
  gp_batch_workload_name             = var.gp_batch_workload_name
  gp_batch_max_vcpus                 = var.gp_batch_max_vcpus
  gp_batch_data_bucket_arn           = aws_s3_bucket.cert_artifacts.arn
  gp_batch_data_bucket_enabled       = true

  # Dedicated worker-gdal ECR repository for the cert GP worker image.
  create_worker_gdal_repo = var.create_worker_gdal_repo

  # Custom-code (UNTRUSTED user code) Batch substrate — SEPARATE + HARDENED.
  # Empty secrets, a minimal task role (scoped to the cert artifact bucket's
  # `customcode/` prefix only — NO DB/secrets), a constrained egress allowlist.
  # The scoped HONUA_JOB_TOKEN (server-injected env) is the trust boundary, not
  # IAM. Off by default; flip enable_customcode_batch on to exercise it. Both
  # python and dotnet (honua-server #2196) runtime families share this one
  # hardened substrate; only the per-runtime image + ECR repo differ.
  enable_customcode_batch              = var.enable_customcode_batch
  customcode_batch_image               = var.customcode_batch_image
  customcode_dotnet_batch_image        = var.customcode_dotnet_batch_image
  customcode_batch_cpu_architecture    = var.customcode_batch_cpu_architecture
  customcode_batch_max_vcpus           = var.customcode_batch_max_vcpus
  customcode_artifact_bucket_arn       = aws_s3_bucket.cert_artifacts.arn
  customcode_artifact_prefix           = "customcode"
  customcode_egress_https_cidrs        = var.customcode_egress_https_cidrs
  create_worker_customcode_repo        = var.create_worker_customcode_repo
  create_worker_customcode_dotnet_repo = var.create_worker_customcode_dotnet_repo

  tags = local.tags
}

# ---------------------------------------------------------------------------
# GitHub Actions -> AWS OIDC federation for the dispatched cert workflow.
# Scoped by `sub` to the cert repo/environment; permissions scoped to the
# honua-cert-* surface (this stack's bucket + Batch + the GP job role).
# ---------------------------------------------------------------------------

module "github_oidc" {
  source = "../../components/aws-github-oidc"

  name_prefix = var.name_prefix
  environment = var.environment

  create_oidc_provider       = var.create_oidc_provider
  existing_oidc_provider_arn = var.existing_oidc_provider_arn

  github_owner         = var.github_owner
  github_repository    = var.github_repository
  github_oidc_subjects = var.github_oidc_subjects

  resource_name_prefix     = local.name
  cert_artifact_bucket_arn = aws_s3_bucket.cert_artifacts.arn
  # PassRole targets for SubmitJob: both the GP job (task) role and the Fargate
  # execution role ride on every submitted job definition.
  batch_job_role_arns = compact([
    module.honua.gp_job_role_arn,
    module.honua.gp_execution_role_arn
  ])

  # ECS/ALB weighted-cutover cell (opt-in): let the cert workflow rewrite the
  # listener's weighted default rule. Scoped to the exact listener ARN plus its
  # listener-rule namespace; empty when the cell is off.
  cert_alb_modify_resource_arns = var.enable_ecs_alb_cert ? [
    aws_lb_listener.cert_cutover[0].arn,
    "${replace(aws_lb_listener.cert_cutover[0].arn, ":listener/", ":listener-rule/")}/*"
  ] : []

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Budget guardrail — monthly cost ceiling + SNS notification.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "budget" {
  #checkov:skip=CKV_AWS_26: SNS encryption-at-rest (KMS) omitted; the topic carries only AWS Budgets cost-threshold alerts (no sensitive payload) and KMS would block the budgets.amazonaws.com publish without extra key-policy wiring.
  name = "${local.name}-budget-alerts"
  tags = local.tags
}

# Allow AWS Budgets to publish threshold notifications to the topic.
data "aws_iam_policy_document" "budget_sns" {
  statement {
    sid       = "AllowBudgetsPublish"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.budget.arn]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "budget" {
  arn    = aws_sns_topic.budget.arn
  policy = data.aws_iam_policy_document.budget_sns.json
}

resource "aws_sns_topic_subscription" "budget_email" {
  for_each = toset(var.budget_alert_emails)

  topic_arn = aws_sns_topic.budget.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_budgets_budget" "cert" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = { for t in var.budget_alert_thresholds_percent : tostring(t) => t }

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_sns_topic_arns  = [aws_sns_topic.budget.arn]
      subscriber_email_addresses = var.budget_alert_emails
    }
  }

  # Forecasted-spend early warning at the highest configured threshold.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = max(var.budget_alert_thresholds_percent...)
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget.arn]
    subscriber_email_addresses = var.budget_alert_emails
  }
}
