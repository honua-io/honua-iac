variable "deployment_safety" {
  description = "Opt-in native ECS/ALB safety wiring for an independently retained Honua controller. Null leaves only ECS startup circuit-breaker protection. No setting asserts live qualification."
  type = object({
    controller_role_name          = string
    telemetry_connection_id       = string
    prometheus_canary_job         = string
    functional_probe_url          = string
    functional_expected_sha256    = string
    observation_window_seconds    = optional(number, 600)
    recovery_timeout_seconds      = optional(number, 300)
    warmup_seconds                = optional(number, 180)
    evidence_grace_seconds        = optional(number, 120)
    max_staleness_seconds         = optional(number, 60)
    exposure_deadline_seconds     = optional(number, 900)
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
