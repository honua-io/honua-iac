###############################################################################
# AWS Batch (Fargate Spot) compute for Honua CUSTOM-CODE jobs (untrusted user
# code).
#
# This is a SEPARATE, deliberately HARDENED Batch substrate that PARALLELS the
# GP substrate in batch.tf but locks it down for running UNTRUSTED user code
# (the custom-code runtimes). The custom-code worker pulls a user-authored
# repo at a pinned SHA, resolves its dependencies (pip for python / `dotnet
# build` for dotnet), runs the user's entrypoint against per-job artifact
# inputs, and writes outputs to a per-job S3 artifact prefix. The user's code
# must NEVER see the platform's database, admin password, master key, or any
# Secrets Manager material.
#
# RUNTIMES (the image is the ONLY per-runtime variation; the security posture is
# runtime-INDEPENDENT). The server accepts customcode.runtime = "python"
# (honua-server Phase 1) or "dotnet" (honua-server #2196, Phase 2) and the
# selector flows through the spec parameters; the iac job-def family resolves it
# to the matching image. Each runtime gets its OWN image + size-tier job-def
# family (customcode-python-{s,m,l,xl}, customcode-dotnet-{s,m,l,xl}) but SHARES
# the SAME minimal task role, the SAME execution role, the SAME constrained
# egress security group, the SAME queue/compute-environment, and the SAME empty
# secrets/env hardening below. The hardening is defined ONCE and reused across
# both runtimes — it is NOT duplicated per runtime.
#
# Hardening — the deliberate deltas from the GP family (batch.tf):
#   - NO Secrets Manager env refs on the job definition. The GDAL job-def injects
#     DB connection string / admin password / master key (batch.tf "environment"
#     block); the custom-code job-def carries an EMPTY secrets/env set. User code
#     gets ONLY the scoped, server-injected runtime env (HONUA_JOB_TOKEN,
#     HONUA_API_ENDPOINT, customcode.output_prefix, etc.) as SubmitJob container
#     overrides — never a secretsmanager:* ARN reference.
#   - A MINIMAL, SEPARATE task (job) role distinct from the GP job role
#     (aws_iam_role.batch_job in batch.tf): NO Secrets Manager access, NO RDS SG
#     ingress, NO broad S3. ONLY (a) pull its own ECR image via the execution
#     role, and (b) s3:PutObject/GetObject scoped to the per-job artifact prefix.
#     The job's callback to Honua is via the scoped HONUA_JOB_TOKEN (server-
#     injected env), NOT via AWS IAM — so the task role is for INFRA only
#     (artifact S3); it intentionally grants no platform-trust permissions.
#   - Private subnets, assignPublicIp = DISABLED (same as GP).
#   - A constrained egress security group: a destination allowlist (PyPI/GitHub
#     for pip+clone, the Honua API endpoint, the artifact S3) rather than an open
#     0.0.0.0/0 HTTPS egress. For MVP this is a CIDR allowlist the operator
#     supplies; full two-phase egress isolation (resolve deps in a network-on
#     phase, then run user code with egress OFF) is a Beta hardening (Phase 3).
#     The SCOPED TOKEN is the primary T1/T2 trust boundary; the egress allowlist
#     is defense-in-depth, not the boundary.
#
# Toggled off by default (enable_customcode_batch = false): existing deploys are
# unchanged unless an operator opts in. References: GP substrate #70; custom-code
# GP design (Phase 1 = this locked-down infra).
###############################################################################

locals {
  customcode_batch_enabled = var.enable_customcode_batch

  customcode_batch_name           = "${local.name}-customcode"
  customcode_batch_default_vcpus  = 1
  customcode_batch_default_memory = 2048

  # Per-runtime custom-code worker image. Each runtime defaults to its own
  # worker-customcode-<runtime> ECR repo this module can create; an operator may
  # override either with a pre-built image (customcode_batch_image pins python;
  # customcode_dotnet_batch_image pins dotnet). The runtime selector
  # (customcode.runtime) the server sends resolves to one of these keys.
  customcode_batch_images = {
    python = var.customcode_batch_image != "" ? var.customcode_batch_image : (
      var.create_worker_customcode_repo ? "${aws_ecr_repository.worker_customcode[0].repository_url}:latest" : var.image
    )
    dotnet = var.customcode_dotnet_batch_image != "" ? var.customcode_dotnet_batch_image : (
      var.create_worker_customcode_dotnet_repo ? "${aws_ecr_repository.worker_customcode_dotnet[0].repository_url}:latest" : var.image
    )
  }

  # The runtimes the substrate provisions a job-def family for. The set is fixed
  # by this module and matches the server's CustomCodeJobContract.SupportedRuntimes
  # (python | dotnet); both families share the identical hardening below.
  customcode_runtimes = ["python", "dotnet"]

  # Size POOL (contract v1), mirrors the GP tiers: a fixed set of job definitions
  # that differ ONLY by ephemeral (scratch) storage — the knob SubmitJob cannot
  # override. vCPU/memory are DEFAULTS the server overrides per job.
  #   *-s  -> 20 GiB (Fargate default; ephemeralStorage block omitted)
  #   *-m  -> 50 GiB
  #   *-l  -> 100 GiB
  #   *-xl -> 200 GiB
  customcode_batch_tiers = {
    s  = null
    m  = 50
    l  = 100
    xl = 200
  }

  # The job-def matrix: one job definition per {runtime}.{tier}. The KEY is
  # "{runtime}.{tier}" (python.s, dotnet.xl, ...) so the server resolves
  # customcode.runtime + the selected size tier to a single job-def ARN. Every
  # entry shares the identical hardened container (same role, same empty
  # secrets/env); only `image` and `ephemeral_gib` vary.
  customcode_batch_jobdefs = local.customcode_batch_enabled ? {
    for pair in setproduct(local.customcode_runtimes, keys(local.customcode_batch_tiers)) :
    "${pair[0]}.${pair[1]}" => {
      runtime       = pair[0]
      tier          = pair[1]
      image         = local.customcode_batch_images[pair[0]]
      ephemeral_gib = local.customcode_batch_tiers[pair[1]]
    }
  } : {}

  # worker-customcode-<runtime> ECR repository names are stable whether or not
  # they are created, so an operator can pre-create + push, then flip the create
  # flag on.
  worker_customcode_repo_name        = "${local.name}-worker-customcode-python"
  worker_customcode_dotnet_repo_name = "${local.name}-worker-customcode-dotnet"

  # S3 artifact prefix the custom-code task role is scoped to. The server sets
  # customcode.output_prefix per job UNDER this prefix; the role grants
  # Get/PutObject only beneath it (never the whole bucket).
  customcode_artifact_prefix = trim(var.customcode_artifact_prefix, "/")
}

# ---------------------------------------------------------------------------
# IAM — custom-code Fargate task EXECUTION role (pulls the image, writes logs).
# Separate from the GP execution role. Same managed policy surface (ECR pull +
# CloudWatch Logs) — this role is the infra launcher, not user-code trust.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "customcode_execution" {
  count              = local.customcode_batch_enabled ? 1 : 0
  name_prefix        = "${local.customcode_batch_name}-exec-"
  assume_role_policy = data.aws_iam_policy_document.batch_execution_assume[0].json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "customcode_execution_ecs" {
  count      = local.customcode_batch_enabled ? 1 : 0
  role       = aws_iam_role.customcode_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---------------------------------------------------------------------------
# IAM — custom-code TASK (job) role: the running UNTRUSTED container's own
# permissions. THIS IS THE HARDENED ROLE. Distinct from the GP job role
# (aws_iam_role.batch_job). It grants:
#   - NOTHING from Secrets Manager (no GetSecretValue, no secret ARNs).
#   - NO RDS reach (no SG ingress is granted to RDS for this role's tasks).
#   - NO broad S3 — ONLY s3:GetObject/PutObject under the per-job artifact
#     prefix the server sets (customcode.output_prefix), and ONLY when an
#     artifact bucket is supplied.
# The Honua callback uses the scoped HONUA_JOB_TOKEN (server-injected env), NOT
# AWS IAM, so this role carries no platform-trust permissions at all.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "customcode_job" {
  count              = local.customcode_batch_enabled ? 1 : 0
  name_prefix        = "${local.customcode_batch_name}-job-"
  assume_role_policy = data.aws_iam_policy_document.batch_execution_assume[0].json
  tags               = local.tags
}

# Scoped artifact S3: Get/PutObject under the per-job artifact prefix ONLY. No
# ListBucket, no DeleteObject, no bucket-wide grant — and deliberately NO
# secretsmanager / rds / kms statements. Only created when an artifact bucket is
# supplied; without it the role has ZERO inline permissions (image pull is on
# the execution role).
resource "aws_iam_role_policy" "customcode_job_artifacts" {
  count = local.customcode_batch_enabled && var.customcode_artifact_bucket_arn != "" ? 1 : 0
  name  = "${local.customcode_batch_name}-job-artifacts"
  role  = aws_iam_role.customcode_job[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ScopedArtifactObjectAccess"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject"]
        # Scoped to the per-job artifact prefix only (customcode.output_prefix is
        # set by the server UNDER this prefix). NOT the whole bucket.
        Resource = ["${var.customcode_artifact_bucket_arn}/${local.customcode_artifact_prefix}/*"]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Security group — CONSTRAINED egress allowlist (NOT open 0.0.0.0/0).
# Untrusted user code reaches ONLY the operator-supplied destination allowlist:
# PyPI/GitHub (pip + clone), the Honua API endpoint, and the artifact S3. There
# is deliberately NO RDS (5432) egress and NO RDS SG ingress is granted for this
# group. Full two-phase egress isolation (deps-on / run-off) is a Beta hardening
# (Phase 3); the SCOPED HONUA_JOB_TOKEN is the primary T1/T2 boundary, this
# allowlist is defense-in-depth.
# ---------------------------------------------------------------------------

#checkov:skip=CKV2_AWS_5: Security group is attached to Batch Fargate tasks via the custom-code compute environment.
resource "aws_security_group" "customcode_batch" {
  count = local.customcode_batch_enabled ? 1 : 0
  #checkov:skip=CKV2_AWS_5: Security group is attached to Batch Fargate tasks via the custom-code compute environment.
  name_prefix = "${local.customcode_batch_name}-"
  description = "Honua custom-code (untrusted) Batch task security group — constrained egress allowlist"
  vpc_id      = local.vpc_id

  # HTTPS egress, but ONLY to the operator-supplied destination allowlist
  # (PyPI/GitHub for pip+clone, the Honua API endpoint, the artifact S3),
  # rather than an open 0.0.0.0/0. Default is the VPC CIDR so that, absent an
  # explicit allowlist, custom-code can reach in-VPC interface/gateway endpoints
  # (S3 gateway endpoint, an internal Honua endpoint) but NOT the open internet.
  dynamic "egress" {
    for_each = length(var.customcode_egress_https_cidrs) > 0 ? var.customcode_egress_https_cidrs : [local.vpc_cidr_block]
    content {
      description = "Allowlisted HTTPS egress (PyPI/GitHub/Honua API/artifact S3)"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [egress.value]
    }
  }

  # DNS so pip/clone can resolve allowlisted hostnames. Restricted to the VPC
  # resolver CIDR (operator-supplied; defaults to the VPC CIDR which covers the
  # .2 AmazonProvidedDNS resolver). NO open 0.0.0.0/0 DNS.
  dynamic "egress" {
    for_each = length(var.customcode_egress_dns_cidrs) > 0 ? var.customcode_egress_dns_cidrs : [local.vpc_cidr_block]
    content {
      description = "DNS resolution for allowlisted hosts (UDP)"
      from_port   = 53
      to_port     = 53
      protocol    = "udp"
      cidr_blocks = [egress.value]
    }
  }

  # NOTE: deliberately NO 5432 (PostgreSQL) egress — untrusted code gets no DB
  # reach — and NO aws_security_group_rule granting this SG ingress to RDS.

  tags = local.tags
}

# ---------------------------------------------------------------------------
# CloudWatch log group for custom-code job containers (separate stream).
# ---------------------------------------------------------------------------

#checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
#checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
resource "aws_cloudwatch_log_group" "customcode_batch" {
  count = local.customcode_batch_enabled ? 1 : 0
  #checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
  #checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
  name              = "/aws/batch/${local.customcode_batch_name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

# ---------------------------------------------------------------------------
# Batch compute environment — Fargate Spot, scale-to-zero. Reuses the GP Batch
# SERVICE role (orchestration only; carries no user-code trust) but its OWN
# constrained security group and a SEPARATE compute environment + queue so
# custom-code never shares a queue with trusted GP jobs.
# ---------------------------------------------------------------------------

resource "aws_batch_compute_environment" "customcode" {
  count = local.customcode_batch_enabled ? 1 : 0

  name         = "${local.customcode_batch_name}-ce"
  type         = "MANAGED"
  service_role = aws_iam_role.batch_service[0].arn

  compute_resources {
    type      = "FARGATE_SPOT"
    max_vcpus = var.customcode_batch_max_vcpus

    subnets            = local.private_subnets
    security_group_ids = [aws_security_group.customcode_batch[0].id]
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Batch job queue bound to the custom-code Fargate Spot compute environment.
# ---------------------------------------------------------------------------

resource "aws_batch_job_queue" "customcode" {
  count = local.customcode_batch_enabled ? 1 : 0

  name     = "${local.customcode_batch_name}-queue"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.customcode[0].arn
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Job-definition POOL for the custom-code (untrusted) container — one job-def
# per {runtime}.{tier} (customcode-python-{s,m,l,xl}, customcode-dotnet-{s,m,l,xl}).
#
# Mirrors the GP pool (tiers differ ONLY by ephemeral storage), but with the
# HARDENED container: EMPTY environment/secrets, the SHARED minimal custom-code
# task role, and the per-RUNTIME worker image — the ONLY thing that varies
# across runtimes. Per-job sizing (vCPU, memory, timeout, retry) and the scoped
# runtime env (HONUA_JOB_TOKEN, HONUA_API_ENDPOINT, customcode.output_prefix,
# ...) are applied by the server at SubmitJob time as container overrides — NONE
# of which are templated here. The security posture is identical across runtimes
# because it is sourced from the SAME role/SG/log group, not redefined per family.
# ---------------------------------------------------------------------------

resource "aws_batch_job_definition" "customcode" {
  for_each = local.customcode_batch_jobdefs

  name                  = "${local.customcode_batch_name}-${each.value.runtime}-${each.value.tier}"
  type                  = "container"
  platform_capabilities = ["FARGATE"]

  container_properties = jsonencode(merge({
    image            = each.value.image
    jobRoleArn       = aws_iam_role.customcode_job[0].arn
    executionRoleArn = aws_iam_role.customcode_execution[0].arn

    resourceRequirements = [
      { type = "VCPU", value = tostring(local.customcode_batch_default_vcpus) },
      { type = "MEMORY", value = tostring(local.customcode_batch_default_memory) },
    ]

    networkConfiguration = {
      assignPublicIp = "DISABLED"
    }

    fargatePlatformConfiguration = {
      platformVersion = "LATEST"
    }

    runtimePlatform = {
      cpuArchitecture       = var.customcode_batch_cpu_architecture
      operatingSystemFamily = "LINUX"
    }

    # HARDENING: EMPTY environment/secrets set. Unlike the GDAL job-def, the
    # custom-code job-def injects NO secretsmanager:* refs (no DB conn string,
    # no admin password, no master key). User code receives ONLY the scoped
    # runtime env (HONUA_JOB_TOKEN, HONUA_API_ENDPOINT, customcode.output_prefix,
    # ...) that the server adds as SubmitJob container overrides.
    environment = []
    secrets     = []

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.customcode_batch[0].name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "customcode-${each.value.runtime}"
      }
    }
    },
    each.value.ephemeral_gib == null ? {} : {
      ephemeralStorage = {
        sizeInGiB = each.value.ephemeral_gib
      }
    }
  ))

  retry_strategy {
    attempts = 1
  }

  timeout {
    attempt_duration_seconds = 3600
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# IAM — allow the Lambda (server) role to drive custom-code Batch jobs, scoped
# to the custom-code queue + job definitions ONLY. Mirrors the GP submit policy
# but on the separate custom-code queue.
# ---------------------------------------------------------------------------

resource "aws_iam_role_policy" "lambda_customcode_submit" {
  count = local.customcode_batch_enabled ? 1 : 0
  name  = "${local.customcode_batch_name}-lambda-submit"
  role  = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SubmitAndTerminateCustomCodeScoped"
        Effect = "Allow"
        Action = [
          "batch:SubmitJob",
          "batch:TerminateJob",
          "batch:CancelJob"
        ]
        Resource = concat(
          [aws_batch_job_queue.customcode[0].arn],
          [for jd in aws_batch_job_definition.customcode : "${jd.arn_prefix}:*"]
        )
      },
      {
        # DescribeJobs / ListJobs do not support resource-level scoping.
        Sid    = "DescribeAndListCustomCode"
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
# Dedicated worker-customcode-python ECR repository (optional). Mirrors the
# worker-gdal repo in batch.tf: scan-on-push, KMS (AWS-managed key), an
# image-count lifecycle cap, a stable name so an operator can pre-create + push
# before flipping the flag on.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "worker_customcode" {
  count                = var.create_worker_customcode_repo ? 1 : 0
  name                 = local.worker_customcode_repo_name
  image_tag_mutability = var.worker_customcode_repo_image_tag_mutability
  force_delete         = var.worker_customcode_repo_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    # KMS with the AWS-managed ECR key (no CMK to manage). An inline checkov
    # skip in this module is not honored when the repo is evaluated through the
    # examples/aws-cert module instantiation, so use the real KMS setting (per
    # the #70 lesson on the worker-gdal repo).
    encryption_type = "KMS"
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "worker_customcode" {
  count      = var.create_worker_customcode_repo ? 1 : 0
  repository = aws_ecr_repository.worker_customcode[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Retain only the most recent ${var.worker_customcode_repo_max_image_count} images."
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.worker_customcode_repo_max_image_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Dedicated worker-customcode-dotnet ECR repository (optional). The .NET sibling
# of the worker-customcode-python repo above (honua-server #2196's
# worker-customcode-dotnet image). Same posture: scan-on-push, KMS (AWS-managed
# key), an image-count lifecycle cap, a stable name so an operator can
# pre-create + push before flipping the flag on.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "worker_customcode_dotnet" {
  count                = var.create_worker_customcode_dotnet_repo ? 1 : 0
  name                 = local.worker_customcode_dotnet_repo_name
  image_tag_mutability = var.worker_customcode_dotnet_repo_image_tag_mutability
  force_delete         = var.worker_customcode_dotnet_repo_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    # KMS with the AWS-managed ECR key (no CMK to manage). An inline checkov
    # skip in this module is not honored when the repo is evaluated through the
    # examples/aws-cert module instantiation, so use the real KMS setting (per
    # the #70 lesson on the worker-gdal repo).
    encryption_type = "KMS"
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "worker_customcode_dotnet" {
  count      = var.create_worker_customcode_dotnet_repo ? 1 : 0
  repository = aws_ecr_repository.worker_customcode_dotnet[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Retain only the most recent ${var.worker_customcode_dotnet_repo_max_image_count} images."
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.worker_customcode_dotnet_repo_max_image_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
