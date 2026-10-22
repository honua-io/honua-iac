# Out-of-band migrations: honua-server migrate-only mode (honua-server#6479) as
# a one-shot ECS task.
#
# With migration_task = true the module registers a task definition that runs
# the server image with HONUA_MIGRATE_ONLY=true and the serving tasks' secrets,
# network, roles and environment (including migration_safety), and sets
# HONUA_SKIP_MIGRATIONS=true on the stable and canary task definitions so the
# serving tasks verify the journal and never migrate. The migrator applies the
# migrations with every Database:MigrationSafety gate in force, prints one
# honua.migrate-only/v1 JSON line to stdout and exits with a typed code (0 done,
# 2 bad config, 3 database unreachable, 4 PostGIS incompatible, 5 contract
# approval needed, 6 unannotated contract, 7 backup failed, 8 schema newer than
# binary, 9 lock timeout, 10 migration failed, 11 cancelled). Terraform never
# runs it: the operator runs it between registering a new image and rolling the
# serving services (output.migration_task has the exact commands).
variable "migration_task" {
  description = "Register a one-shot migration task definition (HONUA_MIGRATE_ONLY=true) and set HONUA_SKIP_MIGRATIONS=true on the serving task definitions. Requires a honua-server image with migrate-only mode (honua-server#6479). False (default) keeps the inline startup migrations."
  type        = bool
  default     = false
}

variable "migration_task_image" {
  description = "Image the migration task runs. Empty uses the canary image when canary_enabled, otherwise image. Set it to the new image and apply before changing the serving image, so the migrator can run first."
  type        = string
  default     = ""
  validation {
    condition     = var.migration_task_image == "" || can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]+)?(/[A-Za-z0-9._-]+)+@sha256:[0-9a-f]{64}$", var.migration_task_image))
    error_message = "migration_task_image must be registry/repository@sha256:<64 lowercase hex>; mutable tags are refused."
  }
}

variable "migration_task_additional_env" {
  description = "Environment for the migration task only, applied over the serving environment, for example HONUA_APPROVE_CONTRACT_MIGRATIONS with the nonce a refused run printed. Keeping it here leaves the serving task definitions unchanged."
  type        = map(string)
  default     = {}
}

locals {
  migration_task_enabled = var.migration_task
  migration_task_image   = trimspace(var.migration_task_image) != "" ? var.migration_task_image : (local.canary_enabled ? local.effective_canary_image : var.image)
  # Rendered into runtime_environment, so it wins over additional_env and
  # reaches both the stable and canary task definitions.
  migration_task_serving_environment = local.migration_task_enabled ? { HONUA_SKIP_MIGRATIONS = "true" } : {}
  # The migrator carries the environment of the service it migrates for: the
  # canary's when a canary exists (a new image lands there first), otherwise
  # the stable service's. Migrate-only mode ignores HONUA_SKIP_MIGRATIONS; it is
  # dropped anyway so the definition reads truthfully.
  migration_task_base_environment = local.canary_enabled ? local.canary_container_environment : local.primary_container_environment
  migration_task_environment = concat(
    [for entry in local.migration_task_base_environment : entry if entry.name != "HONUA_SKIP_MIGRATIONS" && !contains(keys(var.migration_task_additional_env), entry.name)],
    [for key, value in var.migration_task_additional_env : { name = key, value = value }],
    [{ name = "HONUA_MIGRATE_ONLY", value = "true" }]
  )
  migration_task_container_name = "honua-migrate"
  migration_task_log_prefix     = "honua-migrate"
  migration_task_region         = data.aws_region.current.region
  migration_task_network_configuration = format(
    "awsvpcConfiguration={subnets=[%s],securityGroups=[%s],assignPublicIp=%s}",
    join(",", local.private_subnets),
    aws_security_group.ecs.id,
    var.assign_public_ip ? "ENABLED" : "DISABLED"
  )
  user_environment_keys = [
    for key in keys(merge(var.additional_env, var.canary_additional_env)) : upper(replace(key, ":", "__"))
  ]
  migration_task_env_keys = [for key in keys(var.migration_task_additional_env) : upper(key)]
}

resource "terraform_data" "migration_task_validation" {
  lifecycle {
    precondition {
      condition     = !contains(local.user_environment_keys, "HONUA_MIGRATE_ONLY") && !contains(local.migration_task_env_keys, "HONUA_MIGRATE_ONLY")
      error_message = "HONUA_MIGRATE_ONLY must not be set in additional_env, canary_additional_env or migration_task_additional_env: it turns a serving task into a migrator that exits. Use migration_task = true."
    }
    precondition {
      condition     = !local.migration_task_enabled || !contains(local.user_environment_keys, "HONUA_SKIP_MIGRATIONS")
      error_message = "migration_task sets HONUA_SKIP_MIGRATIONS=true on the serving tasks; remove HONUA_SKIP_MIGRATIONS from additional_env and canary_additional_env."
    }
    precondition {
      condition     = !contains(local.migration_task_env_keys, "HONUA_SKIP_MIGRATIONS")
      error_message = "migration_task_additional_env must not set HONUA_SKIP_MIGRATIONS; migrate-only mode ignores it."
    }
    precondition {
      condition     = local.migration_task_enabled || (length(var.migration_task_additional_env) == 0 && trimspace(var.migration_task_image) == "")
      error_message = "migration_task_image and migration_task_additional_env apply only with migration_task = true."
    }
  }
}

resource "aws_ecs_task_definition" "migrate" {
  count = local.migration_task_enabled ? 1 : 0
  # Keep registered revisions, like the serving task definitions, so a revision
  # named in a runbook or receipt stays runnable.
  skip_destroy             = true
  family                   = "${local.name}-migrate-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.container_cpu
  memory                   = var.container_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = upper(var.task_cpu_architecture)
  }

  # No port mappings or health check: the migrator starts no listener and exits.
  container_definitions = jsonencode([
    {
      name        = local.migration_task_container_name
      image       = local.migration_task_image
      essential   = true
      environment = local.migration_task_environment
      secrets     = local.container_secrets
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = local.migration_task_log_prefix
        }
      }
      # On SIGTERM the run stops before its next database step (exit 11); give
      # it the Fargate maximum to get there.
      stopTimeout = 120
    }
  ])

  depends_on = [
    aws_secretsmanager_secret_version.db_connection,
    aws_secretsmanager_secret_version.admin_password,
    aws_secretsmanager_secret_version.master_key,
    aws_secretsmanager_secret_version.redis_connection,
    aws_iam_role_policy.transcript_signing,
    terraform_data.transcript_signing_validation,
    terraform_data.migration_task_validation
  ]

  tags = merge(local.tags, {
    DeploymentSlot = "migrate"
  })
}

output "migration_task" {
  description = "One-shot migration task (honua-server migrate-only mode) and the commands to run it, wait for it, and read its exit code and summary. Null unless migration_task = true."
  value = !local.migration_task_enabled ? null : {
    task_definition_arn = aws_ecs_task_definition.migrate[0].arn
    family              = aws_ecs_task_definition.migrate[0].family
    image               = local.migration_task_image
    cluster_arn         = aws_ecs_cluster.this.arn
    launch_type         = "FARGATE"
    subnets             = local.private_subnets
    security_groups     = [aws_security_group.ecs.id]
    assign_public_ip    = var.assign_public_ip ? "ENABLED" : "DISABLED"
    container_name      = local.migration_task_container_name
    log_group           = aws_cloudwatch_log_group.this.name
    log_stream_prefix   = "${local.migration_task_log_prefix}/${local.migration_task_container_name}/"
    # Prints the task ARN; capture it as TASK_ARN for the commands below.
    run_task_command = "aws ecs run-task --region ${local.migration_task_region} --cluster ${aws_ecs_cluster.this.arn} --task-definition ${aws_ecs_task_definition.migrate[0].arn} --launch-type FARGATE --count 1 --started-by honua-migrate --network-configuration '${local.migration_task_network_configuration}' --query 'tasks[0].taskArn' --output text"
    # The waiter gives up after 10 minutes (exit 255) while the task keeps
    # running; re-run it until it returns 0.
    wait_command = "aws ecs wait tasks-stopped --region ${local.migration_task_region} --cluster ${aws_ecs_cluster.this.arn} --tasks \"$TASK_ARN\""
    # Prints the container exit code and the task's stoppedReason. An exit code
    # of None means the container never ran (image pull, secrets or network).
    exit_code_command = "aws ecs describe-tasks --region ${local.migration_task_region} --cluster ${aws_ecs_cluster.this.arn} --tasks \"$TASK_ARN\" --query \"tasks[0].[containers[?name=='${local.migration_task_container_name}'].exitCode | [0], stoppedReason]\" --output text"
    # Prints the honua.migrate-only/v1 summary line from the task's log stream.
    summary_command = "aws logs filter-log-events --region ${local.migration_task_region} --log-group-name ${aws_cloudwatch_log_group.this.name} --log-stream-names \"${local.migration_task_log_prefix}/${local.migration_task_container_name}/$${TASK_ARN##*/}\" --filter-pattern '\"honua.migrate-only/v1\"' --query 'events[].message' --output text"
  }
}
