# Pass-throughs for the module's in-service deploy control plane,
# Database:MigrationSafety settings and out-of-band migration task. The module
# validates them; see modules/aws-ecs/README.md "Upgrade safety".
variable "deploy_control_plane" {
  description = "Opt-in in-service honua-aws-ecs-alb deploy target and CloudWatch telemetry connection, rendered into the stable and canary task environments. Requires canary_enabled; mutually exclusive with deployment_safety. Null renders nothing."
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
}

variable "migration_safety" {
  description = "Optional Database:MigrationSafety settings (contract_apply_policy Gate|Auto, backup_command, enforce) for the inline startup migrations. Null keeps the server defaults."
  type = object({
    contract_apply_policy = optional(string, "Gate")
    backup_command        = optional(string)
    enforce               = optional(bool)
  })
  default = null
}

output "deploy_control_plane" {
  description = "In-service deploy target registration (configured-unverified), or null."
  value       = module.honua.deploy_control_plane
}

variable "migration_task" {
  description = "Register a one-shot migrate-only ECS task definition (HONUA_MIGRATE_ONLY=true) and set HONUA_SKIP_MIGRATIONS=true on the serving tasks. Requires a honua-server image with migrate-only mode. False keeps inline startup migrations."
  type        = bool
  default     = false
}

variable "migration_task_image" {
  description = "Digest-pinned image for the migration task. Empty uses the canary image when canary_enabled, otherwise honua_image. Set it first, run the task, then change the serving image."
  type        = string
  default     = ""
}

variable "migration_task_additional_env" {
  description = "Environment for the migration task only, for example HONUA_APPROVE_CONTRACT_MIGRATIONS with the nonce a refused run printed."
  type        = map(string)
  default     = {}
}

output "migration_task" {
  description = "Migration task definition and the exact aws ecs run-task / wait / describe-tasks / logs commands, or null when migration_task is false."
  value       = module.honua.migration_task
}
