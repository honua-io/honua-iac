###############################################################################
# AWS Batch (Fargate Spot) compute for Honua geoprocessing / import jobs.
#
# "GP over Batch": the Honua server's ExecutionJobReconciler submits and observes
# geoprocessing/import jobs via the AwsBatchComputeBackend (TargetKind=AwsBatch,
# Backend=honua-aws-batch). Terraform provisions a DURABLE per-environment GP
# substrate: one Fargate-Spot scale-to-zero compute environment, one job queue,
# the IAM roles, the worker-gdal ECR repo, and a small POOL of job definitions
# that differ ONLY by ephemeral (scratch) storage — the single knob AWS Batch
# SubmitJob cannot override. Everything else (vCPU, memory, timeout, retry,
# per-job env) is overridden at SubmitJob time by the server, so terraform does
# NOT template those per job. The server picks the right size tier (s/m/l/xl)
# per job and submits against its job-definition ARN with the runtime overrides.
#
# Cost posture (budget-tight demo):
#   - Fargate Spot capacity (~70% cheaper than on-demand Fargate).
#   - Compute environment scales to zero (min_vcpus = 0): nothing stays warm,
#     you pay only for the seconds a job's container actually runs.
#   - Modest job-def DEFAULT sizing (1 vCPU / 2 GB); the server overrides per job.
#
# Toggled off by default (enable_gp_batch = false) so existing deploys are
# unchanged unless an operator opts in.
###############################################################################

locals {
  gp_batch_enabled = var.enable_gp_batch

  # AWS Batch on Fargate requires a vCPU/memory pairing from the supported
  # Fargate task-size matrix. The job-def DEFAULT (1 vCPU / 2048 MiB) is a valid
  # pairing and intentionally modest; the server overrides VCPU/MEMORY per job at
  # SubmitJob time, so these are only the baseline a bare submit inherits.
  gp_batch_name           = "${local.name}-gp"
  gp_batch_default_vcpus  = 1
  gp_batch_default_memory = 2048

  # GP container image defaults to the same image the Lambda runs (a single
  # Honua image that branches to the GP worker via HONUA_JOB_KIND env), unless
  # the operator supplies a dedicated GP image.
  gp_batch_image = var.gp_batch_image != "" ? var.gp_batch_image : var.image

  # Job-definition size POOL (contract v1). A fixed set of job definitions that
  # differ ONLY by ephemeral (scratch) storage — the knob SubmitJob cannot
  # override. vCPU/memory are DEFAULTS the server overrides per job; the tier is
  # selected per job by the server to pick the disk floor a GP job needs.
  #   gp-s  -> 20 GiB  (Fargate default; ephemeralStorage block omitted)
  #   gp-m  -> 50 GiB
  #   gp-l  -> 100 GiB
  #   gp-xl -> 200 GiB
  # 20 GiB is the Fargate default and the minimum the ephemeralStorage block
  # accepts is 21, so the "s" tier omits the block entirely (null) and lets the
  # default apply. for_each over this map mints the pool as one resource block.
  gp_batch_tiers = local.gp_batch_enabled ? {
    s  = null
    m  = 50
    l  = 100
    xl = 200
  } : {}

  # worker-gdal ECR repository name is stable whether or not it is created, so an
  # operator can pre-create + push, then flip create_worker_gdal_repo on.
  worker_gdal_repo_name = "${local.name}-worker-gdal"
}

# ---------------------------------------------------------------------------
# IAM — Batch service role (orchestrates the compute environment)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "batch_service_assume" {
  count = local.gp_batch_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["batch.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "batch_service" {
  count              = local.gp_batch_enabled ? 1 : 0
  name_prefix        = "${local.gp_batch_name}-svc-"
  assume_role_policy = data.aws_iam_policy_document.batch_service_assume[0].json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "batch_service" {
  count      = local.gp_batch_enabled ? 1 : 0
  role       = aws_iam_role.batch_service[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

# ---------------------------------------------------------------------------
# IAM — Fargate task execution role (pulls the image, writes logs)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "batch_execution_assume" {
  count = local.gp_batch_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "batch_execution" {
  count              = local.gp_batch_enabled ? 1 : 0
  name_prefix        = "${local.gp_batch_name}-exec-"
  assume_role_policy = data.aws_iam_policy_document.batch_execution_assume[0].json
  tags               = local.tags
}

# Standard ECS task-execution managed policy grants ECR pull + CloudWatch Logs
# create/put — exactly what a Fargate task launcher needs.
resource "aws_iam_role_policy_attachment" "batch_execution_ecs" {
  count      = local.gp_batch_enabled ? 1 : 0
  role       = aws_iam_role.batch_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---------------------------------------------------------------------------
# IAM — Job (task) role: the running GP container's own permissions.
# Mirrors how the Lambda reaches the DB (Secrets Manager connection string)
# and, when FileStorage is on S3, the data bucket. Scoped least-privilege.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "batch_job" {
  count              = local.gp_batch_enabled ? 1 : 0
  name_prefix        = "${local.gp_batch_name}-job-"
  assume_role_policy = data.aws_iam_policy_document.batch_execution_assume[0].json
  tags               = local.tags
}

# Same secrets the Lambda reads (DB connection string, admin/master key, redis).
resource "aws_iam_role_policy" "batch_job_secrets" {
  count = local.gp_batch_enabled ? 1 : 0
  name  = "${local.gp_batch_name}-job-secrets"
  role  = aws_iam_role.batch_job[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = compact([
          aws_secretsmanager_secret.connection_string.arn,
          aws_secretsmanager_secret.admin_password.arn,
          local.redis_enabled ? aws_secretsmanager_secret.redis_connection[0].arn : null
        ])
      }
    ]
  })
}

# Optional: S3 access for GP jobs that read/write the FileStorage data bucket.
# Provided by the caller (the aws-demo root owns the bucket) so the module does
# not assume a bucket exists.
resource "aws_iam_role_policy" "batch_job_s3" {
  count = local.gp_batch_enabled && var.gp_batch_data_bucket_arn != "" ? 1 : 0
  name  = "${local.gp_batch_name}-job-s3"
  role  = aws_iam_role.batch_job[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["${var.gp_batch_data_bucket_arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [var.gp_batch_data_bucket_arn]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Security group — egress only (DB + HTTPS for ECR/Secrets/S3).
# The GP container needs the same DB reach as the Lambda; ingress to RDS is
# granted below.
# ---------------------------------------------------------------------------

#checkov:skip=CKV2_AWS_5: Security group is attached to Batch Fargate tasks via the compute environment.
resource "aws_security_group" "batch" {
  count = local.gp_batch_enabled ? 1 : 0
  #checkov:skip=CKV2_AWS_5: Security group is attached to Batch Fargate tasks via the compute environment.
  name_prefix = "${local.gp_batch_name}-"
  description = "Honua GP Batch task security group"
  vpc_id      = local.vpc_id

  egress {
    description = "PostgreSQL access"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr_block]
  }

  dynamic "egress" {
    for_each = local.db_use_existing ? [1] : []
    content {
      description = "Existing PostgreSQL access"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    description = "Outbound HTTPS (ECR, Secrets Manager, S3, CloudWatch)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

# Let the GP Batch task reach the module-managed RDS instance.
resource "aws_security_group_rule" "rds_from_batch" {
  count                    = local.gp_batch_enabled && !local.db_use_existing ? 1 : 0
  type                     = "ingress"
  description              = "PostgreSQL from GP Batch tasks"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds[0].id
  source_security_group_id = aws_security_group.batch[0].id
}

# ---------------------------------------------------------------------------
# CloudWatch log group for GP job containers.
# ---------------------------------------------------------------------------

#checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
#checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
resource "aws_cloudwatch_log_group" "batch" {
  count = local.gp_batch_enabled ? 1 : 0
  #checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
  #checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
  name              = "/aws/batch/${local.gp_batch_name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

# ---------------------------------------------------------------------------
# Batch compute environment — Fargate Spot, scale-to-zero.
# ---------------------------------------------------------------------------

resource "aws_batch_compute_environment" "gp" {
  count = local.gp_batch_enabled ? 1 : 0

  name         = "${local.gp_batch_name}-ce"
  type         = "MANAGED"
  service_role = aws_iam_role.batch_service[0].arn

  compute_resources {
    type      = "FARGATE_SPOT"
    max_vcpus = var.gp_batch_max_vcpus
    # No min_vcpus / desired_vcpus: Fargate compute environments scale to zero
    # automatically. Nothing runs (and nothing is billed) between jobs.

    subnets            = local.private_subnets
    security_group_ids = [aws_security_group.batch[0].id]
  }

  tags = local.tags

  # Avoid the documented in-place-update race where Batch keeps the old CE in
  # INVALID state while the new one comes up.
  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Batch job queue bound to the Fargate Spot compute environment.
# ---------------------------------------------------------------------------

resource "aws_batch_job_queue" "gp" {
  count = local.gp_batch_enabled ? 1 : 0

  name     = "${local.gp_batch_name}-queue"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.gp[0].arn
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Job-definition size POOL for the geoprocessing container.
#
# A fixed pool of job definitions (gp-s / gp-m / gp-l / gp-xl) that differ ONLY
# by ephemeral (scratch) storage — the one knob AWS Batch SubmitJob CANNOT
# override. All other per-job sizing (vCPU, memory, timeout, retry) is applied
# at SubmitJob time by the server's AwsBatchComputeBackend, so the vCPU/memory
# here are just DEFAULTS, and timeout/retry are job-definition baselines the
# submit overrides. for_each over local.gp_batch_tiers mints the pool from one
# block. The server selects a tier per job by its disk floor and submits against
# that tier's job-definition ARN (see the gp_job_definition_arns output).
# ---------------------------------------------------------------------------

resource "aws_batch_job_definition" "gp" {
  for_each = local.gp_batch_tiers

  name                  = "${local.gp_batch_name}-${each.key}"
  type                  = "container"
  platform_capabilities = ["FARGATE"]

  container_properties = jsonencode(merge({
    image            = local.gp_batch_image
    jobRoleArn       = aws_iam_role.batch_job[0].arn
    executionRoleArn = aws_iam_role.batch_execution[0].arn

    # vCPU/MEMORY are job-def DEFAULTS the server overrides per job at SubmitJob
    # time (ContainerOverrides). GPU is out of scope on the Fargate-Spot path
    # (see var.gp_gpu_enabled): GPU needs an EC2 compute environment.
    resourceRequirements = [
      { type = "VCPU", value = tostring(local.gp_batch_default_vcpus) },
      { type = "MEMORY", value = tostring(local.gp_batch_default_memory) },
    ]

    networkConfiguration = {
      assignPublicIp = "DISABLED"
    }

    fargatePlatformConfiguration = {
      platformVersion = "LATEST"
    }

    runtimePlatform = {
      cpuArchitecture       = var.gp_batch_cpu_architecture
      operatingSystemFamily = "LINUX"
    }

    # Baseline environment so the GP container can resolve the database the same
    # way the Lambda does. Per-job env (HONUA_OPERATION_ID, workload name, and
    # any env.* spec parameters) is injected by the backend as container
    # overrides at submit time.
    environment = [
      {
        name  = "ConnectionStrings__DefaultConnection"
        value = "aws:secretsmanager:${aws_secretsmanager_secret.connection_string.arn}"
      },
      {
        name  = "HONUA_ADMIN_PASSWORD"
        value = "aws:secretsmanager:${aws_secretsmanager_secret.admin_password.arn}"
      },
      {
        name  = "Security__ConnectionEncryption__MasterKey"
        value = "aws:secretsmanager:${aws_secretsmanager_secret.admin_password.arn}"
      }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.batch[0].name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "gp"
      }
    }
    },
    # Ephemeral storage is the ONLY per-tier difference and the only knob
    # SubmitJob cannot override. The "s" tier (each.value == null) omits the
    # block to inherit the Fargate 20 GiB default; m/l/xl pin 50/100/200 GiB.
    each.value == null ? {} : {
      ephemeralStorage = {
        sizeInGiB = each.value
      }
    }
  ))

  # Job-definition baselines; the server overrides both per job at SubmitJob time.
  retry_strategy {
    attempts = 1
  }

  timeout {
    attempt_duration_seconds = 3600
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# IAM — allow the Lambda execution role to drive Batch jobs (least-privilege,
# scoped to this queue + job definition). The server's AwsBatchComputeBackend
# calls SubmitJob / DescribeJobs / TerminateJob.
# ---------------------------------------------------------------------------

resource "aws_iam_role_policy" "lambda_batch_submit" {
  count = local.gp_batch_enabled ? 1 : 0
  name  = "${local.gp_batch_name}-lambda-submit"
  role  = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SubmitAndTerminateScoped"
        Effect = "Allow"
        Action = [
          "batch:SubmitJob",
          "batch:TerminateJob",
          "batch:CancelJob"
        ]
        # SubmitJob authorizes on both the queue and the job definition; every
        # tier's job-definition ARN is matched with a revision wildcard so new
        # revisions from later applies keep working.
        Resource = concat(
          [aws_batch_job_queue.gp[0].arn],
          [for jd in aws_batch_job_definition.gp : "${jd.arn_prefix}:*"]
        )
      },
      {
        # DescribeJobs and ListJobs do not support resource-level scoping in
        # IAM; the reconciler needs them to observe and to discover pending
        # submissions by name.
        Sid    = "DescribeAndList"
        Effect = "Allow"
        Action = [
          "batch:DescribeJobs",
          "batch:ListJobs"
        ]
        Resource = ["*"]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Dedicated worker-gdal ECR repository (optional).
# Gives the GP/GDAL worker image its own lifecycle, decoupled from the Honua
# Lambda image. Off by default (create_worker_gdal_repo = false) because GP
# defaults to reusing the Lambda image via HONUA_JOB_KIND. The repository name
# is stable regardless of the flag so an operator can pre-create + push, then
# flip the flag on. Scan-on-push is enabled; encryption uses AES256 (no
# external KMS key dependency); a lifecycle policy caps retained images.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "worker_gdal" {
  count                = var.create_worker_gdal_repo ? 1 : 0
  name                 = local.worker_gdal_repo_name
  image_tag_mutability = var.worker_gdal_repo_image_tag_mutability
  force_delete         = var.worker_gdal_repo_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    # KMS with the AWS-managed ECR key (no CMK to manage). An inline checkov
    # skip in this module is not honored when the repo is evaluated through the
    # examples/aws-cert module instantiation, so use the real KMS setting.
    encryption_type = "KMS"
  }

  tags = local.tags
}

# Expire all but the most-recent N images so the GP worker repo does not
# accumulate storage cost across job-specific tags.
resource "aws_ecr_lifecycle_policy" "worker_gdal" {
  count      = var.create_worker_gdal_repo ? 1 : 0
  repository = aws_ecr_repository.worker_gdal[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Retain only the most recent ${var.worker_gdal_repo_max_image_count} images."
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.worker_gdal_repo_max_image_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
