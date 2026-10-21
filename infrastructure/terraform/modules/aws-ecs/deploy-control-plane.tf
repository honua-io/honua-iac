# In-service ECS/ALB deploy control plane (opt-in).
#
# deployment_safety (deployment-safety.tf) hands the native honua-aws-ecs-alb
# backend to an independently retained controller and gives the workload tasks
# no rollout permissions. This file is the alternative topology: the serving
# Honua tasks register the deploy target and a CloudWatch telemetry connection
# themselves, through ControlPlane__DeployTargets__0__* and
# ControlPlane__TelemetryConnections__0__*, and the shared task role is allowed
# to move the canary service and the weighted traffic rule. Every MultiNode task
# reconciles active deploy operations under a lease, so the catalog,
# connection and permissions go to the stable AND canary task definitions. The
# candidate can therefore act on its own rollout. The two topologies are
# mutually exclusive; prefer deployment_safety where an external controller
# exists.
variable "deploy_control_plane" {
  description = "Opt-in in-service registration of this cell's honua-aws-ecs-alb deploy target and a CloudWatch telemetry connection in the stable and canary task environments, plus the matching task-role permissions. Null (default) renders nothing. Mutually exclusive with deployment_safety. No setting asserts live qualification."
  type = object({
    target_id                  = optional(string)
    requires_approval          = optional(bool, true)
    canary_weight_percentage   = optional(number)
    telemetry_connection_id    = optional(string, "aws-cloudwatch")
    telemetry_timeout_seconds  = optional(number, 10)
    latency_p95_threshold_ms   = optional(number, 1500)
    sample_count_minimum       = optional(number, 50)
    error_rate_threshold       = optional(number, 0.05)
    error_rate_query           = optional(string)
    latency_p95_query          = optional(string)
    sample_count_query         = optional(string)
    healthz_url                = optional(string)
    observation_window_seconds = optional(number, 600)
    recovery_timeout_seconds   = optional(number, 300)
    warmup_seconds             = optional(number, 180)
    evidence_grace_seconds     = optional(number, 900)
    exposure_deadline_seconds  = optional(number, 1800)
  })
  default = null

  validation {
    condition = var.deploy_control_plane == null ? true : alltrue([
      var.deploy_control_plane.target_id == null ? true : can(regex("^[A-Za-z0-9][A-Za-z0-9_.:/-]{0,127}$", var.deploy_control_plane.target_id)),
      can(regex("^[A-Za-z0-9_.:-]+$", var.deploy_control_plane.telemetry_connection_id)),
      var.deploy_control_plane.healthz_url == null ? true : can(regex("^https://[^/@?#]+/[^#]*$", var.deploy_control_plane.healthz_url)),
    ])
    error_message = "deploy_control_plane.target_id must be 1-128 identifier characters, telemetry_connection_id must match ^[A-Za-z0-9_.:-]+$, and healthz_url must be an HTTPS URL without credentials."
  }

  validation {
    condition = var.deploy_control_plane == null ? true : (
      var.deploy_control_plane.canary_weight_percentage == null ? true : (
        var.deploy_control_plane.canary_weight_percentage > 0 &&
        var.deploy_control_plane.canary_weight_percentage < 100 &&
        floor(var.deploy_control_plane.canary_weight_percentage) == var.deploy_control_plane.canary_weight_percentage
      )
    )
    error_message = "deploy_control_plane.canary_weight_percentage must be a whole percentage greater than 0 and less than 100 (the honua-aws-ecs-alb backend rejects other values), or null for a direct cutover."
  }

  validation {
    condition = var.deploy_control_plane == null ? true : alltrue([
      var.deploy_control_plane.telemetry_timeout_seconds > 0 && var.deploy_control_plane.telemetry_timeout_seconds <= 300,
      var.deploy_control_plane.latency_p95_threshold_ms > 0,
      var.deploy_control_plane.sample_count_minimum >= 1,
      var.deploy_control_plane.error_rate_threshold > 0 && var.deploy_control_plane.error_rate_threshold < 1,
    ])
    error_message = "deploy_control_plane thresholds: telemetry_timeout_seconds in (0, 300], latency_p95_threshold_ms > 0, sample_count_minimum >= 1, error_rate_threshold in (0, 1)."
  }

  validation {
    condition = var.deploy_control_plane == null ? true : alltrue([
      for bound in [
        [var.deploy_control_plane.observation_window_seconds, 86400],
        [var.deploy_control_plane.recovery_timeout_seconds, 1800],
        [var.deploy_control_plane.warmup_seconds, 21600],
        [var.deploy_control_plane.evidence_grace_seconds, 3600],
        [var.deploy_control_plane.exposure_deadline_seconds, 7200],
      ] : bound[0] > 0 && bound[0] <= bound[1] && floor(bound[0]) == bound[0]
    ])
    error_message = "deploy_control_plane durations must be positive whole seconds within the runtime limits (observation 86400, recovery 1800, warmup 21600, grace 3600, exposure 7200)."
  }
}

locals {
  deploy_control_plane_enabled = var.deploy_control_plane != null

  # ALB metrics are published per LoadBalancer + TargetGroup. Scoping every
  # query to the canary target group keeps the stable service's traffic out of
  # the candidate's evidence, which the server requires for a split rollout.
  deploy_control_plane_alb_search = local.deploy_control_plane_enabled && local.canary_enabled ? join("", [
    "{AWS/ApplicationELB,LoadBalancer,TargetGroup} ",
    "LoadBalancer=\"${aws_lb.this.arn_suffix}\" ",
    "TargetGroup=\"${aws_lb_target_group.canary[0].arn_suffix}\"",
  ]) : ""

  # Defaults cover the sample floor and p95 latency. ALB does not publish
  # HTTPCode_Target_5XX_Count for a period with no 5XX responses, and the
  # server's CloudWatch reader evaluates one expression whose missing series
  # reads as "no evidence", so a synthesized error ratio would hold a healthy
  # rollout until the evidence grace expires and then roll it back. The
  # error-rate signal is rendered only when the operator supplies a query
  # (honua-io/honua-server#6474).
  deploy_control_plane_sample_count_query = !local.deploy_control_plane_enabled ? null : coalesce(
    var.deploy_control_plane.sample_count_query,
    "SUM(SEARCH('${local.deploy_control_plane_alb_search} MetricName=\"RequestCount\"', 'Sum', 300))"
  )
  deploy_control_plane_latency_p95_query = !local.deploy_control_plane_enabled ? null : coalesce(
    var.deploy_control_plane.latency_p95_query,
    "MAX(SEARCH('${local.deploy_control_plane_alb_search} MetricName=\"TargetResponseTime\"', 'p95', 300)) * 1000"
  )

  deploy_control_plane_target_id = !local.deploy_control_plane_enabled ? null : coalesce(
    var.deploy_control_plane.target_id,
    "${local.name}-ecs"
  )

  deploy_control_plane_parameters = !local.deploy_control_plane_enabled || !local.canary_enabled ? {} : merge(
    {
      "aws.region"                                       = data.aws_region.current.region
      "aws.ecs.cluster"                                  = aws_ecs_cluster.this.arn
      "aws.ecs.canary_service"                           = "${local.name}-canary-service"
      "aws.ecs.stable_service"                           = "${local.name}-service"
      "aws.alb.listener_rule_arn"                        = aws_lb_listener_rule.protected_rollout[0].arn
      "aws.alb.stable_target_group_arn"                  = aws_lb_target_group.this.arn
      "aws.alb.canary_target_group_arn"                  = aws_lb_target_group.canary[0].arn
      "deployment.protection.observation_window_seconds" = tostring(var.deploy_control_plane.observation_window_seconds)
      "deployment.rollback.observation_timeout_seconds"  = tostring(var.deploy_control_plane.recovery_timeout_seconds)
      "telemetry.connection"                             = var.deploy_control_plane.telemetry_connection_id
      "telemetry.sample_count.query"                     = local.deploy_control_plane_sample_count_query
      "telemetry.sample_count.minimum"                   = tostring(var.deploy_control_plane.sample_count_minimum)
      "telemetry.latency_p95.query"                      = local.deploy_control_plane_latency_p95_query
      "telemetry.latency_p95.threshold_ms"               = tostring(var.deploy_control_plane.latency_p95_threshold_ms)
      "telemetry.warmup_seconds"                         = tostring(var.deploy_control_plane.warmup_seconds)
      "telemetry.evidence_grace_seconds"                 = tostring(var.deploy_control_plane.evidence_grace_seconds)
      "telemetry.exposure_deadline_seconds"              = tostring(var.deploy_control_plane.exposure_deadline_seconds)
    },
    var.deploy_control_plane.canary_weight_percentage == null ? {} : {
      "aws.ecs.canary_weight_percentage" = tostring(var.deploy_control_plane.canary_weight_percentage)
    },
    var.deploy_control_plane.error_rate_query == null ? {} : {
      "telemetry.error_rate.query"     = var.deploy_control_plane.error_rate_query
      "telemetry.error_rate.threshold" = tostring(var.deploy_control_plane.error_rate_threshold)
    },
    var.deploy_control_plane.healthz_url == null ? {} : {
      "telemetry.healthz.url" = var.deploy_control_plane.healthz_url
    }
  )

  # Parameter keys contain dots, so they travel as ParameterEntries (the
  # environment-friendly form of DeployTargetOptions.Parameters). Sorted keys
  # keep the task definition stable across plans.
  deploy_control_plane_environment = !local.deploy_control_plane_enabled || !local.canary_enabled ? {} : merge(
    {
      ControlPlane__DeployTargets__0__TargetId                    = local.deploy_control_plane_target_id
      ControlPlane__DeployTargets__0__TargetKind                  = "AwsEcs"
      ControlPlane__DeployTargets__0__Backend                     = "honua-aws-ecs-alb"
      ControlPlane__DeployTargets__0__Environment                 = var.environment
      ControlPlane__DeployTargets__0__TargetName                  = "${local.name}-canary-service"
      ControlPlane__DeployTargets__0__RequiresApproval            = tostring(var.deploy_control_plane.requires_approval)
      ControlPlane__DeployTargets__0__RequiresOutOfBandMigrations = "false"
      ControlPlane__TelemetryConnections__0__ConnectionId         = var.deploy_control_plane.telemetry_connection_id
      ControlPlane__TelemetryConnections__0__Provider             = "cloudwatch"
      ControlPlane__TelemetryConnections__0__BaseUrl              = "https://monitoring.${data.aws_region.current.region}.amazonaws.com"
      ControlPlane__TelemetryConnections__0__Region               = data.aws_region.current.region
      ControlPlane__TelemetryConnections__0__TimeoutSeconds       = tostring(var.deploy_control_plane.telemetry_timeout_seconds)
    },
    merge({}, [
      for index, key in sort(keys(local.deploy_control_plane_parameters)) : {
        "ControlPlane__DeployTargets__0__ParameterEntries__${index}__Key"   = key
        "ControlPlane__DeployTargets__0__ParameterEntries__${index}__Value" = local.deploy_control_plane_parameters[key]
      }
    ]...)
  )
}

# Plan-time guards evaluated whenever the block is set, independently of the
# canary-dependent resources below.
resource "terraform_data" "deploy_control_plane_validation" {
  count = local.deploy_control_plane_enabled ? 1 : 0
  input = local.deploy_control_plane_target_id

  lifecycle {
    precondition {
      condition     = var.deployment_safety == null
      error_message = "deploy_control_plane and deployment_safety are mutually exclusive: two controllers would contend for the same weighted traffic rule. Use deployment_safety for an external retained controller, or deploy_control_plane for the in-service controller."
    }
    precondition {
      condition     = local.canary_enabled
      error_message = "deploy_control_plane requires canary_enabled = true: the honua-aws-ecs-alb backend rolls the canary service and shifts weights between the stable and canary target groups."
    }
    precondition {
      condition = alltrue([
        for key in keys(merge(var.additional_env, var.canary_additional_env)) :
        !startswith(lower(replace(key, ":", "__")), "controlplane__deploytargets__") &&
        !startswith(lower(replace(key, ":", "__")), "controlplane__telemetryconnections__")
      ])
      error_message = "With deploy_control_plane set the module owns ControlPlane:DeployTargets and ControlPlane:TelemetryConnections; remove those keys from additional_env and canary_additional_env."
    }
  }
}

resource "aws_iam_role_policy" "deploy_control_plane" {
  count = local.deploy_control_plane_enabled && local.canary_enabled ? 1 : 0
  name  = "${local.name}-deploy-control-plane"
  role  = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "HonuaEcsCanaryServiceRollout"
        Effect    = "Allow"
        Action    = ["ecs:DescribeServices", "ecs:UpdateService"]
        Resource  = [aws_ecs_service.canary[0].id]
        Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
      },
      {
        # Rollback reads the stable service's task definition as revision proof.
        Sid       = "HonuaEcsStableServiceIdentity"
        Effect    = "Allow"
        Action    = ["ecs:DescribeServices"]
        Resource  = [aws_ecs_service.this.id]
        Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
      },
      {
        Sid      = "HonuaAlbWeightedRule"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:ModifyRule"]
        Resource = [aws_lb_listener_rule.protected_rollout[0].arn]
      },
      {
        # These describe/read APIs do not support resource-level permissions.
        Sid    = "HonuaDeployTelemetryAndDescribe"
        Effect = "Allow"
        Action = [
          "ecs:DescribeTaskDefinition",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetHealth",
          "cloudwatch:GetMetricData",
        ]
        Resource = "*"
      }
    ]
  })
}

output "deploy_control_plane" {
  description = "In-service deploy target registration rendered into the stable and canary task environments. Configured-unverified: Terraform mocks and plans prove neither the CloudWatch expressions nor a live rollback. Null when deploy_control_plane is unset."
  value = !local.deploy_control_plane_enabled ? null : {
    status                  = "configured-unverified"
    controller_topology     = "in-service-stable-and-canary"
    backend_name            = "honua-aws-ecs-alb"
    target_kind             = "AwsEcs"
    target_id               = local.deploy_control_plane_target_id
    telemetry_connection_id = var.deploy_control_plane.telemetry_connection_id
    telemetry_provider      = "cloudwatch"
    error_rate_signal       = var.deploy_control_plane.error_rate_query != null
    parameters              = local.deploy_control_plane_parameters
    alb_metric_dimensions = local.canary_enabled ? {
      load_balancer       = aws_lb.this.arn_suffix
      stable_target_group = aws_lb_target_group.this.arn_suffix
      canary_target_group = aws_lb_target_group.canary[0].arn_suffix
    } : null
  }
  depends_on = [aws_iam_role_policy.deploy_control_plane]
}
