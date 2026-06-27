###############################################################################
# Control-plane event triggers (TriggerMode=Event) — Phase 1 cloud hybrid.
#
# By default the Honua server reconciles execution/deploy jobs on an in-process
# timer. On Lambda there is no always-on host to run that timer, so this gated
# path wires an EVENT-DRIVEN reconcile instead:
#
#   1. A "reconcile" Lambda (batch-event handler) fired by EventBridge whenever a
#      Batch job changes state (source=aws.batch, detail-type="Batch Job State
#      Change"). This is the fast path: the moment a GP/import job completes,
#      fails, or transitions, the reconciler runs and advances the control plane.
#   2. A "backstop" Lambda (backstop handler) fired every ~2 minutes by
#      EventBridge Scheduler. This catches anything the event path missed
#      (dropped events, jobs that never emit a terminal transition, drift) so the
#      control plane still converges without an always-on timer.
#
# Both handlers live in the SAME server image as the API Lambda and select their
# behaviour via HONUA_CONTROL_PLANE_LAMBDA_HANDLER (batch-event | backstop). They
# compose DI identically to the API host (same DB connection, Redis connection,
# admin/master-key secret refs) so the reconcile host can read state and persist
# transitions exactly as the API host would, plus ControlPlane__TriggerMode=Event
# to switch the server off its in-process timer.
#
# Two aws_lambda_function resources share one image but set different handler env
# values (EventBridge cannot select a handler via input transformer). Everything
# here is gated on enable_control_plane_events (default false) so existing
# deploys are unchanged unless an operator opts in.
###############################################################################

locals {
  control_plane_events_enabled = var.enable_control_plane_events

  # Reconcile/backstop Lambdas reuse the API server image by default; an operator
  # can point at a dedicated image (e.g. a tag that bundles the event-handler
  # entrypoint) via control_plane_events_image without disturbing the API image.
  control_plane_events_image = var.control_plane_events_image != "" ? var.control_plane_events_image : var.image

  control_plane_reconcile_function_name = "${local.name}-cp-reconcile"
  control_plane_backstop_function_name  = "${local.name}-cp-backstop"
  control_plane_tick_function_name      = "${local.name}-cp-tick"

  # Phase 3 PERIODIC ticks: one EventBridge Scheduler rule per tick KIND, each invoking the
  # scheduled-tick Lambda with { kind = "<ScheduledTickKind>" } as its input. Only materialised
  # when control-plane events are enabled (Event mode); empty otherwise so Poll deploys are unchanged.
  control_plane_scheduled_tick_schedules = local.control_plane_events_enabled ? var.control_plane_scheduled_tick_schedules : {}

  # Both event handlers compose DI exactly like the API host (local.lambda_environment),
  # then flip the server to event-driven reconciliation (TriggerMode=Event) and
  # select which handler the image runs. The selector value is the ONLY env
  # difference between the reconcile and backstop functions.
  control_plane_events_base_environment = merge(local.lambda_environment, {
    ControlPlane__TriggerMode = "Event"
  })
  control_plane_reconcile_environment = merge(local.control_plane_events_base_environment, {
    HONUA_CONTROL_PLANE_LAMBDA_HANDLER = "batch-event"
  })
  control_plane_backstop_environment = merge(local.control_plane_events_base_environment, {
    HONUA_CONTROL_PLANE_LAMBDA_HANDLER = "backstop"
  })

  # Phase 3 scheduled-tick handler: same image + DI as the other event handlers; the
  # scheduled-tick selector tells the image to read the tick KIND from the invocation event
  # ({ "kind": "<ScheduledTickKind>" }, supplied per-schedule below) and drive that tick once via
  # the server's IScheduledTickDispatcher (the token-guarded /internal/control-plane/scheduled-tick
  # surface). One function serves every kind; the kind is data on the event, not a separate function.
  control_plane_tick_environment = merge(local.control_plane_events_base_environment, {
    HONUA_CONTROL_PLANE_LAMBDA_HANDLER = "scheduled-tick"
  })
}

# ---------------------------------------------------------------------------
# IAM — reconcile/backstop Lambda execution role.
# Mirrors aws_iam_role.lambda (basic + VPC execution managed policies) and grants
# the same Secrets Manager reads the API host needs so DI composes identically,
# plus batch:DescribeJobs so the batch-event handler can observe job state.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "control_plane_events" {
  count              = local.control_plane_events_enabled ? 1 : 0
  name_prefix        = "${local.name}-cp-evt-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "control_plane_events_basic" {
  count      = local.control_plane_events_enabled ? 1 : 0
  role       = aws_iam_role.control_plane_events[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "control_plane_events_vpc" {
  count      = local.control_plane_events_enabled ? 1 : 0
  role       = aws_iam_role.control_plane_events[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Same secret grants the API host gets (DB connection string, admin/master key,
# redis connection, pro license) so the reconcile host builds its DI exactly like
# the API host, plus batch:DescribeJobs to observe Batch job transitions.
#checkov:skip=CKV_AWS_355: KMS Decrypt/GenerateDataKey target the AWS-managed Secrets Manager key, whose ARN is not knowable in-module; no CMK var/resource exists to scope the resource to.
#checkov:skip=CKV_AWS_290: The KMS grant is limited to Decrypt/GenerateDataKey on the unscopable AWS-managed Secrets Manager key (reading the Honua secrets), not unconstrained write/admin access.
resource "aws_iam_role_policy" "control_plane_events" {
  #checkov:skip=CKV_AWS_355: KMS Decrypt/GenerateDataKey target the AWS-managed Secrets Manager key, whose ARN is not knowable in-module; no CMK var/resource exists to scope the resource to.
  #checkov:skip=CKV_AWS_290: The KMS grant is limited to Decrypt/GenerateDataKey on the unscopable AWS-managed Secrets Manager key (reading the Honua secrets), not unconstrained write/admin access.
  count = local.control_plane_events_enabled ? 1 : 0
  name  = "${local.name}-cp-evt"
  role  = aws_iam_role.control_plane_events[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadHonuaSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = compact([
          aws_secretsmanager_secret.connection_string.arn,
          aws_secretsmanager_secret.admin_password.arn,
          local.redis_enabled ? aws_secretsmanager_secret.redis_connection[0].arn : null,
          local.pro_license_enabled ? aws_secretsmanager_secret.pro_license[0].arn : null
        ])
      },
      {
        # DescribeJobs does not support resource-level scoping in IAM; the
        # batch-event handler needs it to read the transitioned job's state.
        Sid      = "DescribeBatchJobs"
        Effect   = "Allow"
        Action   = ["batch:DescribeJobs"]
        Resource = ["*"]
      },
      {
        # The connection-string / admin-password secrets and the redis connection
        # are encrypted with the AWS-managed Secrets Manager KMS key (no CMK is
        # referenced anywhere in this module). KMS decrypt is required to read
        # those secret values, and GenerateDataKey supports the server's
        # ConnectionEncryption master-key derivation. Scoped to KMS Decrypt /
        # GenerateDataKey but on "*" because the AWS-managed key ARN is not known
        # to this module and no CMK var/resource exists to scope to (see the
        # CKV_AWS_355 / CKV_AWS_290 skips on this resource).
        Sid    = "DecryptSecrets"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = ["*"]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# CloudWatch log groups for the reconcile/backstop Lambdas.
# ---------------------------------------------------------------------------

#checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
#checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
resource "aws_cloudwatch_log_group" "control_plane_reconcile" {
  count = local.control_plane_events_enabled ? 1 : 0
  #checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
  #checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
  name              = "/aws/lambda/${local.control_plane_reconcile_function_name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

#checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
#checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
resource "aws_cloudwatch_log_group" "control_plane_backstop" {
  count = local.control_plane_events_enabled ? 1 : 0
  #checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
  #checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
  name              = "/aws/lambda/${local.control_plane_backstop_function_name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

# ---------------------------------------------------------------------------
# Reconcile Lambda — the EventBridge "Batch Job State Change" target
# (HONUA_CONTROL_PLANE_LAMBDA_HANDLER=batch-event). Same image, VPC, security
# group, and DI env as the API Lambda so it can reach Redis + Postgres.
# ---------------------------------------------------------------------------

#checkov:skip=CKV_AWS_50: X-Ray tracing is optional and can be enabled by the deployment environment.
#checkov:skip=CKV_AWS_116: DLQ wiring is environment-specific and not required for every deployment target.
#checkov:skip=CKV_AWS_173: Secrets are injected through Secrets Manager references rather than plaintext environment values.
#checkov:skip=CKV_AWS_272: Code signing is optional for private image-based deployments.
resource "aws_lambda_function" "control_plane_reconcile" {
  count = local.control_plane_events_enabled ? 1 : 0
  #checkov:skip=CKV_AWS_50: X-Ray tracing is optional and can be enabled by the deployment environment.
  #checkov:skip=CKV_AWS_116: DLQ wiring is environment-specific and not required for every deployment target.
  #checkov:skip=CKV_AWS_173: Secrets are injected through Secrets Manager references rather than plaintext environment values.
  #checkov:skip=CKV_AWS_272: Code signing is optional for private image-based deployments.
  function_name = local.control_plane_reconcile_function_name
  role          = aws_iam_role.control_plane_events[0].arn
  package_type  = "Image"
  image_uri     = local.control_plane_events_image
  publish       = true

  memory_size = var.control_plane_events_memory_size
  timeout     = var.control_plane_events_timeout_seconds

  architectures = var.lambda_architectures

  ephemeral_storage {
    size = var.lambda_ephemeral_storage_mb
  }

  reserved_concurrent_executions = var.control_plane_events_reserved_concurrent_executions

  vpc_config {
    subnet_ids         = local.private_subnets
    security_group_ids = [aws_security_group.lambda.id]
  }

  dynamic "tracing_config" {
    for_each = var.enable_xray_tracing ? [1] : []
    content {
      mode = "Active"
    }
  }

  environment {
    variables = local.control_plane_reconcile_environment
  }

  depends_on = [
    aws_ecr_repository_policy.lambda_image_access,
    aws_cloudwatch_log_group.control_plane_reconcile,
    aws_secretsmanager_secret_version.connection_string,
    aws_secretsmanager_secret_version.admin_password,
    aws_secretsmanager_secret_version.redis_connection,
    aws_secretsmanager_secret_version.pro_license
  ]

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Backstop Lambda — the EventBridge Scheduler (rate(2 minutes)) target
# (HONUA_CONTROL_PLANE_LAMBDA_HANDLER=backstop). Identical wiring to the
# reconcile Lambda except for the handler selector.
# ---------------------------------------------------------------------------

#checkov:skip=CKV_AWS_50: X-Ray tracing is optional and can be enabled by the deployment environment.
#checkov:skip=CKV_AWS_116: DLQ wiring is environment-specific and not required for every deployment target.
#checkov:skip=CKV_AWS_173: Secrets are injected through Secrets Manager references rather than plaintext environment values.
#checkov:skip=CKV_AWS_272: Code signing is optional for private image-based deployments.
resource "aws_lambda_function" "control_plane_backstop" {
  count = local.control_plane_events_enabled ? 1 : 0
  #checkov:skip=CKV_AWS_50: X-Ray tracing is optional and can be enabled by the deployment environment.
  #checkov:skip=CKV_AWS_116: DLQ wiring is environment-specific and not required for every deployment target.
  #checkov:skip=CKV_AWS_173: Secrets are injected through Secrets Manager references rather than plaintext environment values.
  #checkov:skip=CKV_AWS_272: Code signing is optional for private image-based deployments.
  function_name = local.control_plane_backstop_function_name
  role          = aws_iam_role.control_plane_events[0].arn
  package_type  = "Image"
  image_uri     = local.control_plane_events_image
  publish       = true

  memory_size = var.control_plane_events_memory_size
  timeout     = var.control_plane_events_timeout_seconds

  architectures = var.lambda_architectures

  ephemeral_storage {
    size = var.lambda_ephemeral_storage_mb
  }

  reserved_concurrent_executions = var.control_plane_events_reserved_concurrent_executions

  vpc_config {
    subnet_ids         = local.private_subnets
    security_group_ids = [aws_security_group.lambda.id]
  }

  dynamic "tracing_config" {
    for_each = var.enable_xray_tracing ? [1] : []
    content {
      mode = "Active"
    }
  }

  environment {
    variables = local.control_plane_backstop_environment
  }

  depends_on = [
    aws_ecr_repository_policy.lambda_image_access,
    aws_cloudwatch_log_group.control_plane_backstop,
    aws_secretsmanager_secret_version.connection_string,
    aws_secretsmanager_secret_version.admin_password,
    aws_secretsmanager_secret_version.redis_connection,
    aws_secretsmanager_secret_version.pro_license
  ]

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Scheduled-tick Lambda (Phase 3) — the EventBridge Scheduler target for the
# PERIODIC (bucket-b) control-plane ticks
# (HONUA_CONTROL_PLANE_LAMBDA_HANDLER=scheduled-tick). Same image, VPC, security
# group, and DI env as the reconcile/backstop Lambdas; the tick KIND is supplied
# per-schedule as the invocation input rather than baked into the function, so a
# single function serves every tick kind.
# ---------------------------------------------------------------------------

#checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
#checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
resource "aws_cloudwatch_log_group" "control_plane_tick" {
  count = local.control_plane_events_enabled ? 1 : 0
  #checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
  #checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
  name              = "/aws/lambda/${local.control_plane_tick_function_name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

#checkov:skip=CKV_AWS_50: X-Ray tracing is optional and can be enabled by the deployment environment.
#checkov:skip=CKV_AWS_116: DLQ wiring is environment-specific and not required for every deployment target.
#checkov:skip=CKV_AWS_173: Secrets are injected through Secrets Manager references rather than plaintext environment values.
#checkov:skip=CKV_AWS_272: Code signing is optional for private image-based deployments.
resource "aws_lambda_function" "control_plane_tick" {
  count = local.control_plane_events_enabled ? 1 : 0
  #checkov:skip=CKV_AWS_50: X-Ray tracing is optional and can be enabled by the deployment environment.
  #checkov:skip=CKV_AWS_116: DLQ wiring is environment-specific and not required for every deployment target.
  #checkov:skip=CKV_AWS_173: Secrets are injected through Secrets Manager references rather than plaintext environment values.
  #checkov:skip=CKV_AWS_272: Code signing is optional for private image-based deployments.
  function_name = local.control_plane_tick_function_name
  role          = aws_iam_role.control_plane_events[0].arn
  package_type  = "Image"
  image_uri     = local.control_plane_events_image
  publish       = true

  memory_size = var.control_plane_events_memory_size
  timeout     = var.control_plane_events_timeout_seconds

  architectures = var.lambda_architectures

  ephemeral_storage {
    size = var.lambda_ephemeral_storage_mb
  }

  reserved_concurrent_executions = var.control_plane_events_reserved_concurrent_executions

  vpc_config {
    subnet_ids         = local.private_subnets
    security_group_ids = [aws_security_group.lambda.id]
  }

  dynamic "tracing_config" {
    for_each = var.enable_xray_tracing ? [1] : []
    content {
      mode = "Active"
    }
  }

  environment {
    variables = local.control_plane_tick_environment
  }

  depends_on = [
    aws_ecr_repository_policy.lambda_image_access,
    aws_cloudwatch_log_group.control_plane_tick,
    aws_secretsmanager_secret_version.connection_string,
    aws_secretsmanager_secret_version.admin_password,
    aws_secretsmanager_secret_version.redis_connection,
    aws_secretsmanager_secret_version.pro_license
  ]

  tags = local.tags
}

# ---------------------------------------------------------------------------
# EventBridge rule — Batch job state changes -> reconcile Lambda.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "control_plane_batch_state_change" {
  count       = local.control_plane_events_enabled ? 1 : 0
  name        = "${local.name}-cp-batch-state"
  description = "Fire the Honua control-plane reconcile Lambda on every Batch job state change."

  event_pattern = jsonencode({
    source      = ["aws.batch"]
    detail-type = ["Batch Job State Change"]
  })

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "control_plane_reconcile" {
  count     = local.control_plane_events_enabled ? 1 : 0
  rule      = aws_cloudwatch_event_rule.control_plane_batch_state_change[0].name
  target_id = "honua-cp-reconcile"
  arn       = aws_lambda_function.control_plane_reconcile[0].arn
}

resource "aws_lambda_permission" "control_plane_events_bridge" {
  count         = local.control_plane_events_enabled ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.control_plane_reconcile[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.control_plane_batch_state_change[0].arn
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler — every ~2 minutes -> backstop Lambda.
# Scheduler targets require a role_arn; the role may only invoke the backstop
# Lambda (least-privilege).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "control_plane_scheduler_assume" {
  count = local.control_plane_events_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "control_plane_scheduler" {
  count              = local.control_plane_events_enabled ? 1 : 0
  name_prefix        = "${local.name}-cp-sch-"
  assume_role_policy = data.aws_iam_policy_document.control_plane_scheduler_assume[0].json
  tags               = local.tags
}

resource "aws_iam_role_policy" "control_plane_scheduler" {
  count = local.control_plane_events_enabled ? 1 : 0
  name  = "${local.name}-cp-scheduler-invoke"
  role  = aws_iam_role.control_plane_scheduler[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The single scheduler role invokes both the backstop Lambda (rate(2 minutes)) and the
        # Phase 3 scheduled-tick Lambda (one schedule per tick kind). Scoped to exactly these two
        # functions (and their versions) — least-privilege, no wildcard function ARNs.
        Sid    = "InvokeControlPlaneScheduledLambdas"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          aws_lambda_function.control_plane_backstop[0].arn,
          "${aws_lambda_function.control_plane_backstop[0].arn}:*",
          aws_lambda_function.control_plane_tick[0].arn,
          "${aws_lambda_function.control_plane_tick[0].arn}:*"
        ]
      }
    ]
  })
}

#checkov:skip=CKV_AWS_297: Schedule payload is a static rate trigger with no sensitive input; CMK encryption of the schedule is optional and supplied by the deployment environment when required.
resource "aws_scheduler_schedule" "control_plane_backstop" {
  #checkov:skip=CKV_AWS_297: Schedule payload is a static rate trigger with no sensitive input; CMK encryption of the schedule is optional and supplied by the deployment environment when required.
  count       = local.control_plane_events_enabled ? 1 : 0
  name        = "${local.name}-cp-backstop"
  description = "Backstop the Honua control-plane reconcile every ~2 minutes (catches missed Batch events / drift)."

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "rate(2 minutes)"

  group_name = aws_scheduler_schedule_group.control_plane[0].name

  target {
    arn      = aws_lambda_function.control_plane_backstop[0].arn
    role_arn = aws_iam_role.control_plane_scheduler[0].arn
  }
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler — PERIODIC (bucket-b) control-plane ticks (Phase 3).
# One schedule per tick KIND, all in a single scheduler group, each invoking the
# scheduled-tick Lambda with { "kind": "<ScheduledTickKind>" } as input. The
# Lambda's scheduled-tick handler reads the kind and drives that tick once via
# IScheduledTickDispatcher. Cadences come from
# var.control_plane_scheduled_tick_schedules (defaults mirror the in-process
# timer intervals). Reuses the same scheduler role + image as the backstop path.
# ---------------------------------------------------------------------------

resource "aws_scheduler_schedule_group" "control_plane" {
  count = local.control_plane_events_enabled ? 1 : 0
  name  = "${local.name}-cp"
  tags  = local.tags
}

#checkov:skip=CKV_AWS_297: Schedule payload is a static tick-kind trigger with no sensitive input; CMK encryption of the schedule is optional and supplied by the deployment environment when required.
resource "aws_scheduler_schedule" "control_plane_tick" {
  #checkov:skip=CKV_AWS_297: Schedule payload is a static tick-kind trigger with no sensitive input; CMK encryption of the schedule is optional and supplied by the deployment environment when required.
  for_each = local.control_plane_scheduled_tick_schedules

  name        = "${local.name}-cp-tick-${lower(each.key)}"
  description = "Drive the Honua control-plane ${each.key} tick on its configured cadence (TriggerMode=Event)."

  group_name = aws_scheduler_schedule_group.control_plane[0].name

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = each.value

  target {
    arn      = aws_lambda_function.control_plane_tick[0].arn
    role_arn = aws_iam_role.control_plane_scheduler[0].arn
    input    = jsonencode({ kind = each.key })
  }
}
