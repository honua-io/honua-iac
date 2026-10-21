# Weighted Lambda alias canaries (opt-in).
#
# Two independent inputs:
#
#   * lambda_alias_routing pins a weighted split on the live alias from
#     Terraform: routing_config.additional_version_weights sends `weight` of
#     traffic to one additional published version. Use it for an operator-run
#     canary without the control plane.
#
#   * lambda_deploy_canary lets the server's honua-gitops-aws-lambda backend
#     shift those weights itself. It adds aws.lambda.canary_weight_percentage
#     and telemetry.* gate parameters to the version-pinned deploy target, adds
#     a CloudWatch entry under ControlPlane:TelemetryConnections in the same
#     settings document, and grants cloudwatch:GetMetricData to the API role.
#
# Lambda publishes per-version metrics under the ExecutedVersion dimension, but
# the candidate version is only known when a deploy operation is planned. The
# module therefore cannot pin candidate-scoped queries on the target: supply
# telemetry.sample_count.query / telemetry.latency_p95.query (and optionally
# telemetry.error_rate.query) as operation parameter overrides, with the
# candidate version substituted into the templates this file outputs. A
# target-level aggregate query would let the stable version's traffic mask a
# failing candidate, which the server refuses for a split rollout.
#
# Terraform owns the alias. While an operation holds weighted traffic on it, do
# not apply this module: an apply resets routing_config to lambda_alias_routing.
variable "lambda_alias_routing" {
  description = "Optional weighted routing on the live alias: { additional_version = \"<published version>\", weight = <0..1 exclusive> } renders routing_config.additional_version_weights. Null (default) routes all alias traffic to the alias version."
  type = object({
    additional_version = string
    weight             = number
  })
  default = null

  validation {
    condition = var.lambda_alias_routing == null ? true : (
      can(regex("^[1-9][0-9]*$", var.lambda_alias_routing.additional_version)) &&
      var.lambda_alias_routing.weight > 0 &&
      var.lambda_alias_routing.weight < 1
    )
    error_message = "lambda_alias_routing.additional_version must be a published version number (never $LATEST) and weight must be greater than 0 and less than 1."
  }
}

variable "lambda_deploy_canary" {
  description = "Opt-in control-plane canary for the honua-gitops-aws-lambda backend: renders aws.lambda.canary_weight_percentage and telemetry gate parameters on the deploy target and a CloudWatch ControlPlane:TelemetryConnections entry in the settings document. Changing it changes the settings document hash, so carry the previous runtime_settings_retention_entry first. Null (default) renders nothing."
  type = object({
    weight_percentage          = number
    telemetry_connection_id    = optional(string, "aws-cloudwatch")
    telemetry_timeout_seconds  = optional(number, 10)
    latency_p95_threshold_ms   = optional(number, 3000)
    sample_count_minimum       = optional(number, 50)
    error_rate_threshold       = optional(number)
    observation_window_seconds = optional(number, 600)
    warmup_seconds             = optional(number, 180)
    evidence_grace_seconds     = optional(number, 900)
    exposure_deadline_seconds  = optional(number, 1800)
  })
  default = null

  validation {
    condition = var.lambda_deploy_canary == null ? true : alltrue([
      var.lambda_deploy_canary.weight_percentage > 0 && var.lambda_deploy_canary.weight_percentage < 100,
      can(regex("^[A-Za-z0-9_.:-]+$", var.lambda_deploy_canary.telemetry_connection_id)),
      var.lambda_deploy_canary.telemetry_timeout_seconds > 0 && var.lambda_deploy_canary.telemetry_timeout_seconds <= 300,
      var.lambda_deploy_canary.latency_p95_threshold_ms > 0,
      var.lambda_deploy_canary.sample_count_minimum >= 1,
      var.lambda_deploy_canary.error_rate_threshold == null ? true : (var.lambda_deploy_canary.error_rate_threshold > 0 && var.lambda_deploy_canary.error_rate_threshold < 1),
    ])
    error_message = "lambda_deploy_canary: weight_percentage in (0, 100), telemetry_connection_id matching ^[A-Za-z0-9_.:-]+$, telemetry_timeout_seconds in (0, 300], latency_p95_threshold_ms > 0, sample_count_minimum >= 1, error_rate_threshold null or in (0, 1)."
  }

  validation {
    condition = var.lambda_deploy_canary == null ? true : alltrue([
      for bound in [
        [var.lambda_deploy_canary.observation_window_seconds, 86400],
        [var.lambda_deploy_canary.warmup_seconds, 21600],
        [var.lambda_deploy_canary.evidence_grace_seconds, 3600],
        [var.lambda_deploy_canary.exposure_deadline_seconds, 7200],
      ] : bound[0] > 0 && bound[0] <= bound[1] && floor(bound[0]) == bound[0]
    ])
    error_message = "lambda_deploy_canary durations must be positive whole seconds within the runtime limits (observation 86400, warmup 21600, grace 3600, exposure 7200)."
  }
}

locals {
  lambda_deploy_canary_enabled = var.lambda_deploy_canary != null

  lambda_deploy_canary_parameters = !local.lambda_deploy_canary_enabled ? {} : merge(
    {
      "aws.lambda.canary_weight_percentage"              = tostring(var.lambda_deploy_canary.weight_percentage)
      "deployment.protection.observation_window_seconds" = tostring(var.lambda_deploy_canary.observation_window_seconds)
      "telemetry.connection"                             = var.lambda_deploy_canary.telemetry_connection_id
      "telemetry.sample_count.minimum"                   = tostring(var.lambda_deploy_canary.sample_count_minimum)
      "telemetry.latency_p95.threshold_ms"               = tostring(var.lambda_deploy_canary.latency_p95_threshold_ms)
      "telemetry.warmup_seconds"                         = tostring(var.lambda_deploy_canary.warmup_seconds)
      "telemetry.evidence_grace_seconds"                 = tostring(var.lambda_deploy_canary.evidence_grace_seconds)
      "telemetry.exposure_deadline_seconds"              = tostring(var.lambda_deploy_canary.exposure_deadline_seconds)
    },
    var.lambda_deploy_canary.error_rate_threshold == null ? {} : {
      "telemetry.error_rate.threshold" = tostring(var.lambda_deploy_canary.error_rate_threshold)
    }
  )

  lambda_deploy_canary_telemetry_connections = !local.lambda_deploy_canary_enabled ? {} : {
    TelemetryConnections = [{
      ConnectionId   = var.lambda_deploy_canary.telemetry_connection_id
      Provider       = "cloudwatch"
      BaseUrl        = "https://monitoring.${data.aws_region.current.name}.amazonaws.com"
      Region         = data.aws_region.current.name
      TimeoutSeconds = var.lambda_deploy_canary.telemetry_timeout_seconds
    }]
  }

  # Candidate-scoped CloudWatch metric-math templates; replace {version} with
  # the operation's desired published version. Errors are published only for
  # periods with failed invocations, so an error-rate expression can read as
  # "no evidence" on a healthy candidate (see README).
  lambda_deploy_canary_search = "{AWS/Lambda,FunctionName,Resource,ExecutedVersion} FunctionName=\"${local.lambda_function_name}\" Resource=\"${local.lambda_function_name}:${var.lambda_alias_name}\" ExecutedVersion=\"{version}\""
  lambda_deploy_canary_query_templates = !local.lambda_deploy_canary_enabled ? null : {
    "telemetry.sample_count.query" = "SUM(SEARCH('${local.lambda_deploy_canary_search} MetricName=\"Invocations\"', 'Sum', 300))"
    "telemetry.latency_p95.query"  = "MAX(SEARCH('${local.lambda_deploy_canary_search} MetricName=\"Duration\"', 'p95', 300))"
    "telemetry.error_rate.query"   = "SUM(SEARCH('${local.lambda_deploy_canary_search} MetricName=\"Errors\"', 'Sum', 300)) / SUM(SEARCH('${local.lambda_deploy_canary_search} MetricName=\"Invocations\"', 'Sum', 300))"
  }
}

resource "aws_iam_role_policy" "lambda_deploy_telemetry" {
  count = local.lambda_deploy_canary_enabled ? 1 : 0
  name  = "${local.name}-lambda-deploy-telemetry"
  role  = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetMetricData does not support resource-level permissions.
        Sid      = "HonuaDeployTelemetryRead"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData"]
        Resource = "*"
      }
    ]
  })

  lifecycle {
    precondition {
      condition = alltrue([
        for key in keys(var.additional_env) :
        !startswith(lower(replace(key, ":", "__")), "controlplane__telemetryconnections__")
      ])
      error_message = "With lambda_deploy_canary set the module owns ControlPlane:TelemetryConnections in the settings document; remove those keys from additional_env."
    }
  }
}

output "lambda_deploy_canary" {
  description = "Control-plane canary registration for the honua-gitops-aws-lambda target (configured-unverified), with candidate-scoped CloudWatch query templates to pass as operation parameter overrides after replacing {version}. Null when lambda_deploy_canary is unset."
  value = !local.lambda_deploy_canary_enabled ? null : {
    status                  = "configured-unverified"
    backend_name            = "honua-gitops-aws-lambda"
    target_id               = local.lambda_target_id
    telemetry_connection_id = var.lambda_deploy_canary.telemetry_connection_id
    telemetry_provider      = "cloudwatch"
    parameters              = local.lambda_deploy_canary_parameters
    query_templates         = local.lambda_deploy_canary_query_templates
  }
}
