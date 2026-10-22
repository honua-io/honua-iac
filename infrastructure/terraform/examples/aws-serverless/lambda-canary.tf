# Pass-throughs for the module's weighted alias canary inputs; the module
# validates both. See modules/aws-serverless/README.md "Weighted alias canaries".
variable "lambda_alias_routing" {
  description = "Optional { additional_version, weight } weighted split on the live alias (routing_config.additional_version_weights). Null routes all alias traffic to the alias version."
  type = object({
    additional_version = string
    weight             = number
  })
  default = null
}

variable "lambda_deploy_canary" {
  description = "Optional control-plane canary for the honua-gitops-aws-lambda target: canary weight and telemetry gate parameters plus a CloudWatch telemetry connection in the settings document. Null renders nothing."
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
}

output "lambda_deploy_canary" {
  description = "Control-plane canary registration and candidate-scoped query templates (configured-unverified), or null."
  value       = module.honua.lambda_deploy_canary
}
