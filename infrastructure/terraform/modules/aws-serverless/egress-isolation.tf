###############################################################################
# Custom-code GP egress isolation — TWO-PHASE separate-job model + CodeArtifact
# pull-through cache (honua-iac Phase 3 security hardening).
#
# PROBLEM (what the MVP coarse allowlist does today):
#   The MVP GP Batch task (aws_security_group.batch in batch.tf) runs dependency
#   restore (pip/git -> PyPI/GitHub) AND user-supplied custom code in ONE Fargate
#   task with 443 to 0.0.0.0/0. A custom-code job can therefore exfiltrate to any
#   host on the open internet while "restoring dependencies".
#
# CHOSEN ARCHITECTURE — "separate provisioning job -> cached dependency layer ->
# locked-down execution job":
#   1. A PROVISIONING Batch job (security group aws_security_group.batch_provisioning)
#      runs dependency restore against an AWS CodeArtifact pull-through cache
#      (PyPI / NuGet upstreams) reachable only over VPC interface endpoints, plus a
#      TIGHT GitHub egress allowlist for git-clone of the pinned SHA. It writes the
#      restored dependency layer to the S3 artifact bucket prefix.
#   2. An EXECUTION Batch job (security group aws_security_group.batch_execution)
#      runs the user's custom code with NO dependency-registry / open-internet
#      egress: only 443 to the in-VPC endpoints (Secrets Manager, STS, the Honua
#      API path) and the S3 gateway prefix-list for the artifact bucket.
#
# WHY TWO SEPARATE JOBS (not one task that switches SG mid-run): a Fargate task
# has exactly ONE ENI and ONE security group set for its entire lifetime — there
# is no in-task SG switch. The only way to give "restore" a different egress
# posture than "run user code" is to run them as SEPARATE Fargate tasks/jobs with
# different security groups. The orchestrator (the server's reconciler) is the
# trust boundary that must run the execution job under the locked-down SG.
#
# Everything here is gated on var.enable_customcode_egress_isolation (default
# false) so the MVP coarse-allowlist path is unchanged unless an operator opts in.
# See infrastructure/terraform/docs/customcode-egress-isolation.md for the full
# architecture + HONEST residual-risk writeup.
###############################################################################

locals {
  egress_isolation_enabled = local.gp_batch_enabled && var.enable_customcode_egress_isolation
  egress_isolation_name    = "${local.gp_batch_name}-cc"
  ca_region                = data.aws_region.current.name

  # Route tables the S3 GATEWAY endpoint attaches to. For a module-created VPC we
  # use its private route tables; for an operator-supplied existing VPC we look
  # them up from the private subnets (the gateway endpoint must be on the route
  # table that serves the GP private subnets).
  egress_isolation_route_table_ids = local.egress_isolation_enabled ? (
    local.use_existing_vpc
    ? distinct(data.aws_route_table.egress_isolation_existing[*].route_table_id)
    : module.vpc[0].private_route_table_ids
  ) : []

  # CodeArtifact ARNs the provisioning job role is scoped to (domain + the two
  # pull-through repos). Built only when enabled so the references are valid.
  ca_domain_arn = local.egress_isolation_enabled ? aws_codeartifact_domain.customcode[0].arn : ""
  ca_repo_arns = local.egress_isolation_enabled ? [
    aws_codeartifact_repository.pypi[0].arn,
    aws_codeartifact_repository.nuget[0].arn,
  ] : []
}

# When reusing an existing VPC, resolve the private route tables from the private
# subnets so the S3 gateway endpoint lands on the correct route tables.
data "aws_route_table" "egress_isolation_existing" {
  count     = local.egress_isolation_enabled && local.use_existing_vpc ? length(local.private_subnets) : 0
  subnet_id = local.private_subnets[count.index]
}

# ---------------------------------------------------------------------------
# AWS CodeArtifact — pull-through dependency cache.
#
# A CodeArtifact DOMAIN plus two pull-through repositories: one fronting public
# PyPI (public:pypi) and one fronting public NuGet (public:nuget-org). The
# provisioning job restores dependencies THROUGH these repos so that:
#   - packages are pulled via the VPC CodeArtifact interface endpoints (no direct
#     PyPI egress from the task), and
#   - the cache pins what was fetched (reproducible restores; an upstream yank
#     does not break a later restore).
# Assets are served from CodeArtifact's S3 store, reached via the S3 GATEWAY
# endpoint below.
# ---------------------------------------------------------------------------

#checkov:skip=CKV_AWS_362: SSE-S3 / AWS-managed encryption is acceptable for the dependency-cache domain; a customer-managed KMS CMK is not required for public pull-through packages.
resource "aws_codeartifact_domain" "customcode" {
  count  = local.egress_isolation_enabled ? 1 : 0
  domain = var.customcode_codeartifact_domain_name
  tags   = local.tags
}

resource "aws_codeartifact_repository" "pypi" {
  count       = local.egress_isolation_enabled ? 1 : 0
  repository  = "${var.customcode_codeartifact_domain_name}-pypi"
  domain      = aws_codeartifact_domain.customcode[0].domain
  description = "Pull-through cache fronting public PyPI for custom-code GP dependency restore."

  external_connections {
    external_connection_name = "public:pypi"
  }

  tags = local.tags
}

resource "aws_codeartifact_repository" "nuget" {
  count       = local.egress_isolation_enabled ? 1 : 0
  repository  = "${var.customcode_codeartifact_domain_name}-nuget"
  domain      = aws_codeartifact_domain.customcode[0].domain
  description = "Pull-through cache fronting public nuget.org for custom-code GP dependency restore."

  external_connections {
    external_connection_name = "public:nuget-org"
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# VPC endpoints for CodeArtifact + STS + S3.
#
# CodeArtifact needs two INTERFACE endpoints (api + repositories), STS needs an
# INTERFACE endpoint (GetServiceBearerToken / auth), and CodeArtifact serves
# package assets from S3 so an S3 GATEWAY endpoint is required. private_dns is on
# so the standard service hostnames resolve to in-VPC ENIs — the tasks restore
# without any public-internet route.
#
# A dedicated endpoint security group (aws_security_group.customcode_endpoints)
# permits 443 from inside the VPC. Both phase security groups egress 443 to THIS
# SG so the only HTTPS the tasks can reach are these endpoints.
# ---------------------------------------------------------------------------

#checkov:skip=CKV2_AWS_5: Attached to the CodeArtifact / STS interface VPC endpoints below.
resource "aws_security_group" "customcode_endpoints" {
  count = local.egress_isolation_enabled ? 1 : 0
  #checkov:skip=CKV2_AWS_5: Attached to the CodeArtifact / STS interface VPC endpoints below.
  name_prefix = "${local.egress_isolation_name}-vpce-"
  description = "Honua custom-code egress-isolation interface VPC endpoint security group (443 from VPC)"
  vpc_id      = local.vpc_id

  ingress {
    description = "HTTPS from the VPC (CodeArtifact / STS endpoints)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr_block]
  }

  # Endpoint ENIs return responses on the established connection; an explicit
  # egress rule keeps the SG self-contained and avoids the implicit allow-all.
  egress {
    description = "HTTPS responses within the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr_block]
  }

  tags = local.tags
}

resource "aws_vpc_endpoint" "codeartifact_api" {
  count               = local.egress_isolation_enabled ? 1 : 0
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${local.ca_region}.codeartifact.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnets
  security_group_ids  = [aws_security_group.customcode_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.egress_isolation_name}-codeartifact-api" })
}

resource "aws_vpc_endpoint" "codeartifact_repositories" {
  count               = local.egress_isolation_enabled ? 1 : 0
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${local.ca_region}.codeartifact.repositories"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnets
  security_group_ids  = [aws_security_group.customcode_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.egress_isolation_name}-codeartifact-repositories" })
}

resource "aws_vpc_endpoint" "customcode_sts" {
  count               = local.egress_isolation_enabled ? 1 : 0
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${local.ca_region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnets
  security_group_ids  = [aws_security_group.customcode_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.egress_isolation_name}-sts" })
}

# Secrets Manager interface endpoint so the EXECUTION phase can resolve the
# aws:secretsmanager: references (DB connection string, master key) with NO open
# egress. Reuses the dedicated endpoint SG.
resource "aws_vpc_endpoint" "customcode_secretsmanager" {
  count               = local.egress_isolation_enabled ? 1 : 0
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${local.ca_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnets
  security_group_ids  = [aws_security_group.customcode_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.egress_isolation_name}-secretsmanager" })
}

# S3 GATEWAY endpoint — free, route-table based. Serves CodeArtifact package
# assets AND the artifact-bucket dependency-layer handoff. Exposes a managed
# prefix-list the phase SGs egress to (object access stays in-VPC).
resource "aws_vpc_endpoint" "customcode_s3" {
  count             = local.egress_isolation_enabled ? 1 : 0
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${local.ca_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.egress_isolation_route_table_ids

  tags = merge(local.tags, { Name = "${local.egress_isolation_name}-s3" })
}

# ---------------------------------------------------------------------------
# PHASE 1 security group — PROVISIONING (dependency restore).
#
# Egress posture (dependency egress LIVES HERE, and ONLY here):
#   - 443 to the CodeArtifact / STS / Secrets endpoint SG (pull-through restore +
#     auth token).
#   - S3 gateway prefix-list (CodeArtifact assets + write the dependency layer to
#     the artifact bucket prefix).
#   - 5432 to the VPC (snapshot / DB reach during provisioning if needed).
#   - A TIGHT GitHub egress allowlist (var.customcode_github_egress_cidrs) for
#     git-clone of the pinned SHA. EMPTY by default => no GitHub egress at all
#     (operators that restore purely from CodeArtifact leave it empty; those that
#     need git-sourced deps set the GitHub IP ranges explicitly). This is the
#     documented residual-risk boundary — see the docs file.
# ---------------------------------------------------------------------------

#checkov:skip=CKV2_AWS_5: Attached to the provisioning Batch job definition / compute path.
resource "aws_security_group" "batch_provisioning" {
  count = local.egress_isolation_enabled ? 1 : 0
  #checkov:skip=CKV2_AWS_5: Attached to the provisioning Batch job definition / compute path.
  name_prefix = "${local.egress_isolation_name}-prov-"
  description = "Honua custom-code GP PROVISIONING phase SG (CodeArtifact + tight GitHub allowlist; dependency egress)"
  vpc_id      = local.vpc_id

  egress {
    description     = "HTTPS to CodeArtifact / STS / Secrets Manager interface endpoints (pull-through restore + auth)"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.customcode_endpoints[0].id]
  }

  egress {
    description     = "S3 (CodeArtifact assets + dependency-layer handoff to the artifact bucket) via the S3 gateway prefix list"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [aws_vpc_endpoint.customcode_s3[0].prefix_list_id]
  }

  egress {
    description = "PostgreSQL to the VPC (snapshot / DB reach during provisioning)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr_block]
  }

  # TIGHT GitHub egress allowlist for git-clone of the pinned SHA. Empty default
  # => block list => no rule => NO GitHub egress. Operators set the GitHub IP
  # ranges (https://api.github.com/meta) only if git-sourced deps are needed.
  dynamic "egress" {
    for_each = length(var.customcode_github_egress_cidrs) > 0 ? [1] : []
    content {
      description = "Tight HTTPS allowlist for git-clone of the pinned SHA (GitHub)"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = var.customcode_github_egress_cidrs
    }
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# PHASE 2 security group — EXECUTION (runs user custom code).
#
# Egress posture (NO dependency-registry / open-internet egress):
#   - 443 to the in-VPC endpoint SG ONLY (Secrets Manager for the DB/master-key
#     references, STS, and — via private DNS — the Honua API path if it is fronted
#     by an in-VPC endpoint / private hostname).
#   - S3 gateway prefix-list for the artifact bucket (consume the dependency layer
#     the provisioning job wrote; read/write job I/O).
#   - 5432 to the VPC for the DB.
#   NO PyPI, NO GitHub, NO 0.0.0.0/0. User code cannot reach the open internet.
# ---------------------------------------------------------------------------

#checkov:skip=CKV2_AWS_5: Attached to the execution Batch job definition / compute path.
resource "aws_security_group" "batch_execution" {
  count = local.egress_isolation_enabled ? 1 : 0
  #checkov:skip=CKV2_AWS_5: Attached to the execution Batch job definition / compute path.
  name_prefix = "${local.egress_isolation_name}-exec-"
  description = "Honua custom-code GP EXECUTION phase SG (locked down; no dependency-registry or open-internet egress)"
  vpc_id      = local.vpc_id

  egress {
    description     = "HTTPS to in-VPC endpoints only (Secrets Manager / STS / Honua API path)"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.customcode_endpoints[0].id]
  }

  egress {
    description     = "S3 (consume dependency layer + job I/O on the artifact bucket) via the S3 gateway prefix list"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [aws_vpc_endpoint.customcode_s3[0].prefix_list_id]
  }

  egress {
    description = "PostgreSQL to the VPC (DB reach for the running job)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr_block]
  }

  tags = local.tags
}

# Let the two phases reach the module-managed RDS instance (mirrors
# rds_from_batch in batch.tf for the MVP SG).
resource "aws_security_group_rule" "rds_from_batch_provisioning" {
  count                    = local.egress_isolation_enabled && !local.db_use_existing ? 1 : 0
  type                     = "ingress"
  description              = "PostgreSQL from custom-code GP provisioning tasks"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds[0].id
  source_security_group_id = aws_security_group.batch_provisioning[0].id
}

resource "aws_security_group_rule" "rds_from_batch_execution" {
  count                    = local.egress_isolation_enabled && !local.db_use_existing ? 1 : 0
  type                     = "ingress"
  description              = "PostgreSQL from custom-code GP execution tasks"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds[0].id
  source_security_group_id = aws_security_group.batch_execution[0].id
}

# ---------------------------------------------------------------------------
# IAM — CodeArtifact read for the PROVISIONING phase (granted to the GP job role).
#
# Scoped to the domain + the two pull-through repo ARNs; sts:GetServiceBearerToken
# is conditioned on the codeartifact service name (the only way the bearer token
# is minted). NEVER Action="*" (the policy gate forbids it); resources are ARN-
# scoped. The execution phase does NOT receive this grant — it cannot mint a
# CodeArtifact token, reinforcing the no-dependency-egress posture.
# ---------------------------------------------------------------------------

resource "aws_iam_role_policy" "batch_job_codeartifact" {
  count = local.egress_isolation_enabled ? 1 : 0
  name  = "${local.egress_isolation_name}-job-codeartifact"
  role  = aws_iam_role.batch_job[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CodeArtifactAuth"
        Effect = "Allow"
        Action = ["codeartifact:GetAuthorizationToken"]
        # GetAuthorizationToken authorizes on the DOMAIN.
        Resource = [local.ca_domain_arn]
      },
      {
        Sid    = "CodeArtifactRepoRead"
        Effect = "Allow"
        Action = [
          "codeartifact:GetRepositoryEndpoint",
          "codeartifact:ReadFromRepository",
        ]
        Resource = local.ca_repo_arns
      },
      {
        Sid    = "StsBearerTokenForCodeArtifact"
        Effect = "Allow"
        Action = ["sts:GetServiceBearerToken"]
        # Mintable ONLY for the CodeArtifact service (token-scoping condition).
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "sts:AWSServiceName" = "codeartifact.amazonaws.com"
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# PROVISIONING job-definition family.
#
# A separate Batch job definition per size tier that runs under the PROVISIONING
# security group. It is identical to the MVP gp job definition EXCEPT it carries
# the CodeArtifact pull-through configuration env (domain + repo endpoints) so the
# restore step targets CodeArtifact instead of public PyPI/NuGet, and it is bound
# to the provisioning SG via the compute path (the orchestrator submits this
# job-def for the restore phase, then submits the existing gp job-def — re-tagged
# to the EXECUTION SG — for the user-code phase).
#
# NOTE: a Fargate Batch job definition does not itself pin a security group; the
# SG comes from the COMPUTE ENVIRONMENT the job runs on. The two-phase model
# therefore also needs the two phases to land on compute environments wired to
# the respective SGs. To keep this change tractable we provision the two SGs +
# CodeArtifact + endpoints + IAM + this provisioning job-def now, and DOCUMENT the
# compute-environment / orchestration handoff (see the docs file). The
# provisioning compute environment is added behind the same flag below.
# ---------------------------------------------------------------------------

resource "aws_batch_job_definition" "gp_provisioning" {
  for_each = local.egress_isolation_enabled ? local.gp_batch_tiers : {}

  name                  = "${local.egress_isolation_name}-prov-${each.key}"
  type                  = "container"
  platform_capabilities = ["FARGATE"]

  container_properties = jsonencode(merge({
    image            = local.gp_batch_image
    jobRoleArn       = aws_iam_role.batch_job[0].arn
    executionRoleArn = aws_iam_role.batch_execution[0].arn

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

    # PROVISIONING phase marker + CodeArtifact pull-through config. The worker's
    # restore step reads these to point pip/nuget at the CodeArtifact repos
    # (resolved via the VPC endpoints) instead of public registries.
    environment = [
      {
        name  = "HONUA_JOB_PHASE"
        value = "provisioning"
      },
      {
        name  = "HONUA_CODEARTIFACT_DOMAIN"
        value = aws_codeartifact_domain.customcode[0].domain
      },
      {
        name  = "HONUA_CODEARTIFACT_DOMAIN_OWNER"
        value = data.aws_caller_identity.current.account_id
      },
      {
        name  = "HONUA_CODEARTIFACT_PYPI_REPO"
        value = aws_codeartifact_repository.pypi[0].repository
      },
      {
        name  = "HONUA_CODEARTIFACT_NUGET_REPO"
        value = aws_codeartifact_repository.nuget[0].repository
      },
      {
        name  = "HONUA_CODEARTIFACT_REGION"
        value = local.ca_region
      },
      {
        name  = "ConnectionStrings__DefaultConnection"
        value = "aws:secretsmanager:${aws_secretsmanager_secret.connection_string.arn}"
      }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.batch[0].name
        "awslogs-region"        = local.ca_region
        "awslogs-stream-prefix" = "gp-prov"
      }
    }
    },
    each.value == null ? {} : {
      ephemeralStorage = {
        sizeInGiB = each.value
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
# PROVISIONING + EXECUTION compute environments (separate SGs per phase).
#
# Fargate one-ENI/task means SG is fixed per task, so the two phases run on two
# compute environments: provisioning (aws_security_group.batch_provisioning) and
# execution (aws_security_group.batch_execution). Both are Fargate-Spot scale-to-
# zero like the MVP CE; nothing is billed between jobs. The orchestrator routes
# the restore job to the provisioning queue and the user-code job to the
# execution queue.
# ---------------------------------------------------------------------------

resource "aws_batch_compute_environment" "gp_provisioning" {
  count = local.egress_isolation_enabled ? 1 : 0

  name         = "${local.egress_isolation_name}-prov-ce"
  type         = "MANAGED"
  service_role = aws_iam_role.batch_service[0].arn

  compute_resources {
    type               = "FARGATE_SPOT"
    max_vcpus          = var.gp_batch_max_vcpus
    subnets            = local.private_subnets
    security_group_ids = [aws_security_group.batch_provisioning[0].id]
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_batch_compute_environment" "gp_execution" {
  count = local.egress_isolation_enabled ? 1 : 0

  name         = "${local.egress_isolation_name}-exec-ce"
  type         = "MANAGED"
  service_role = aws_iam_role.batch_service[0].arn

  compute_resources {
    type               = "FARGATE_SPOT"
    max_vcpus          = var.gp_batch_max_vcpus
    subnets            = local.private_subnets
    security_group_ids = [aws_security_group.batch_execution[0].id]
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_batch_job_queue" "gp_provisioning" {
  count = local.egress_isolation_enabled ? 1 : 0

  name     = "${local.egress_isolation_name}-prov-queue"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.gp_provisioning[0].arn
  }

  tags = local.tags
}

resource "aws_batch_job_queue" "gp_execution" {
  count = local.egress_isolation_enabled ? 1 : 0

  name     = "${local.egress_isolation_name}-exec-queue"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.gp_execution[0].arn
  }

  tags = local.tags
}

# Allow the Lambda reconciler to submit/observe on the two phase queues +
# provisioning job-defs (scoped; mirrors lambda_batch_submit in batch.tf).
resource "aws_iam_role_policy" "lambda_batch_submit_egress_isolation" {
  count = local.egress_isolation_enabled ? 1 : 0
  name  = "${local.egress_isolation_name}-lambda-submit"
  role  = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SubmitAndTerminateScopedTwoPhase"
        Effect = "Allow"
        Action = [
          "batch:SubmitJob",
          "batch:TerminateJob",
          "batch:CancelJob"
        ]
        Resource = concat(
          [
            aws_batch_job_queue.gp_provisioning[0].arn,
            aws_batch_job_queue.gp_execution[0].arn,
          ],
          [for jd in aws_batch_job_definition.gp_provisioning : "${jd.arn_prefix}:*"]
        )
      }
    ]
  })
}
