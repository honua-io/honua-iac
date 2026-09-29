# Native runtime handoff. The supplied controller and telemetry connection are
# retained outside this workload; their live permissions/survival are certified
# by #118, never inferred from a role ARN or a successful Terraform plan.
variable "deployment_safety" {
  description = "Opt-in native ECS/ALB safety wiring for an independently retained Honua controller. Null leaves only ECS startup circuit-breaker protection. No setting asserts live qualification."
  type = object({
    controller_role_name       = string
    telemetry_connection_id    = string
    prometheus_canary_job      = string
    functional_probe_url       = string
    functional_expected_sha256 = string
    observation_window_seconds = optional(number, 600)
    recovery_timeout_seconds   = optional(number, 300)
    warmup_seconds             = optional(number, 180)
    evidence_grace_seconds     = optional(number, 120)
    max_staleness_seconds      = optional(number, 60)
    exposure_deadline_seconds  = optional(number, 900)
  })
  default = null

  validation {
    condition = var.deployment_safety == null ? true : alltrue([
      can(regex("^[A-Za-z0-9_+=,.@-]{1,64}$", var.deployment_safety.controller_role_name)),
      can(regex("^[A-Za-z0-9_.:-]+$", var.deployment_safety.telemetry_connection_id)),
      can(regex("^[A-Za-z0-9_.:-]+$", var.deployment_safety.prometheus_canary_job)),
      can(regex("^https://[^/@?#]+/[^#]*$", var.deployment_safety.functional_probe_url)),
      can(regex("^[0-9a-f]{64}$", var.deployment_safety.functional_expected_sha256)),
    ])
    error_message = "Safety wiring requires a retained IAM role name, telemetry connection ID, dedicated canary job, HTTPS functional URL without credentials, and an independently computed SHA-256 expectation."
  }

  validation {
    condition = var.deployment_safety == null ? true : alltrue([
      for bound in [
        [var.deployment_safety.observation_window_seconds, 86400],
        [var.deployment_safety.recovery_timeout_seconds, 1800],
        [var.deployment_safety.warmup_seconds, 21600],
        [var.deployment_safety.evidence_grace_seconds, 3600],
        [var.deployment_safety.max_staleness_seconds, 3600],
        [var.deployment_safety.exposure_deadline_seconds, 7200],
      ] : bound[0] > 0 && bound[0] <= bound[1] && floor(bound[0]) == bound[0]
    ])
    error_message = "Safety durations must be positive whole seconds within the canonical runtime limits (observation 86400, recovery 1800, warmup 21600, grace/staleness 3600, exposure 7200)."
  }
}

locals {
  safety_enabled = var.deployment_safety != null
}

data "aws_iam_role" "recovery_controller" {
  count = local.safety_enabled ? 1 : 0
  name  = var.deployment_safety.controller_role_name
}

# The native backend mutates a RULE, not a listener default action. The
# higher-priority header rule still permits candidate-only functional probes.
resource "aws_lb_listener_rule" "protected_rollout" {
  count        = local.safety_enabled ? 1 : 0
  listener_arn = local.use_https ? aws_lb_listener.https[0].arn : aws_lb_listener.http[0].arn
  priority     = 50000

  action {
    type = "forward"
    forward {
      # Installed at stable=100/candidate=0 regardless of canary_weight_percentage:
      # the retained controller has not yet registered or observed the candidate,
      # so no candidate-serving traffic may exist before it takes ownership below.
      target_group {
        arn    = aws_lb_target_group.this.arn
        weight = 100
      }
      target_group {
        arn    = aws_lb_target_group.canary[0].arn
        weight = 0
      }
    }
  }
  condition {
    path_pattern { values = ["/*"] }
  }

  lifecycle {
    # After installation the canonical controller owns traffic weights.
    ignore_changes = [action]
    precondition {
      condition     = local.canary_enabled && local.multi_node_topology_ready && var.desired_count >= 1 && var.canary_desired_count >= 1
      error_message = "Native safety requires running stable and canary services, MultiNode, Redis and shared S3 storage."
    }
    precondition {
      condition     = var.canary_listener_rule_priority < 50000
      error_message = "The candidate verification header rule must precede the protected traffic rule (priority < 50000)."
    }
    precondition {
      condition     = can(regex("@sha256:[0-9a-f]{64}$", var.image)) && can(regex("@sha256:[0-9a-f]{64}$", local.effective_canary_image))
      error_message = "Safety requires digest-pinned stable and canary images; retained mutable tags cannot identify a recoverable revision."
    }
  }
}

resource "aws_iam_role_policy" "recovery_controller" {
  count = local.safety_enabled ? 1 : 0
  name  = "${local.name}-recovery"
  role  = data.aws_iam_role.recovery_controller[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["ecs:DescribeServices", "ecs:UpdateService"]
        Resource  = [aws_ecs_service.canary[0].id]
        Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:ModifyRule"]
        Resource = [aws_lb_listener_rule.protected_rollout[0].arn]
      },
      {
        # These describe APIs do not support resource-level permissions.
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition", "elasticloadbalancing:DescribeRules", "elasticloadbalancing:DescribeTargetHealth"]
        Resource = "*"
      }
    ]
  })
  lifecycle {
    precondition {
      condition     = !contains([aws_iam_role.task.name, aws_iam_role.task_execution.name], var.deployment_safety.controller_role_name)
      error_message = "The recovery controller must use an independent retained role, not the candidate task or execution role."
    }
  }
}

output "deployment_safety" {
  description = "Native backend registration and bounded canonical runtime parameters. Configured-unverified until exact-candidate provider recovery evidence passes. No secrets or live-protection assertion."
  value = !local.safety_enabled ? null : {
    status                  = "configured-unverified"
    backend_name            = "honua-aws-ecs-alb"
    target_kind             = "AwsEcs"
    target_id               = aws_ecs_service.canary[0].id
    controller_role_arn     = data.aws_iam_role.recovery_controller[0].arn
    controller_topology     = "external-retained-controller"
    durable_operation_store = "external-controller-required"
    evidence_owner          = "honua-iac#118"
    parameters = {
      "aws.region"                                       = data.aws_region.current.region
      "aws.ecs.cluster"                                  = aws_ecs_cluster.this.arn
      "aws.ecs.canary_service"                           = aws_ecs_service.canary[0].name
      "aws.alb.listener_rule_arn"                        = aws_lb_listener_rule.protected_rollout[0].arn
      "aws.alb.stable_target_group_arn"                  = aws_lb_target_group.this.arn
      "aws.alb.canary_target_group_arn"                  = aws_lb_target_group.canary[0].arn
      "deployment.protection.observation_window_seconds" = tostring(var.deployment_safety.observation_window_seconds)
      "deployment.rollback.observation_timeout_seconds"  = tostring(var.deployment_safety.recovery_timeout_seconds)
      "telemetry.connection"                             = var.deployment_safety.telemetry_connection_id
      "telemetry.policy"                                 = "aws-alb-canary"
      "telemetry.prometheus.canary_job"                  = var.deployment_safety.prometheus_canary_job
      "telemetry.healthz.url"                            = "${local.service_scheme}://${local.service_host}${var.health_check_path}"
      "telemetry.golden_query.url"                       = var.deployment_safety.functional_probe_url
      "telemetry.golden_query.expected_sha256"           = var.deployment_safety.functional_expected_sha256
      "telemetry.warmup_seconds"                         = tostring(var.deployment_safety.warmup_seconds)
      "telemetry.evidence_grace_seconds"                 = tostring(var.deployment_safety.evidence_grace_seconds)
      "telemetry.max_staleness_seconds"                  = tostring(var.deployment_safety.max_staleness_seconds)
      "telemetry.exposure_deadline_seconds"              = tostring(var.deployment_safety.exposure_deadline_seconds)
    }
  }
  depends_on = [aws_iam_role_policy.recovery_controller]
}
