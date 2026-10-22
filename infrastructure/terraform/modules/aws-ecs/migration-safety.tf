# Database migration safety for the inline (startup) migration path.
#
# ECS tasks apply pending migrations at startup behind a PostgreSQL advisory
# lock. Database:MigrationSafety decides what happens when a pending migration
# is a reviewed contract-phase (schema-narrowing) script on an existing
# database: Gate (the server default) refuses it until the one-shot
# HONUA_APPROVE_CONTRACT_MIGRATIONS nonce from the refusal is supplied; Auto
# applies it unattended. BackupCommand runs inside the server container
# immediately before contract-phase scripts apply; a non-zero exit aborts.
#
# Out-of-band migrations (HONUA_SKIP_MIGRATIONS=true on serving tasks plus a
# one-shot `aws ecs run-task` migrator) are not wired: the server image has no
# migrate-and-exit entry point yet (honua-io/honua-server#6470).
variable "migration_safety" {
  description = "Optional Database:MigrationSafety settings rendered on the stable and canary task definitions as Database__MigrationSafety__{ContractApplyPolicy,BackupCommand,Enforce}. Null (default) renders nothing and keeps the server defaults (ContractApplyPolicy=Gate, Enforce=true, no backup command). Typed values win over the same keys in additional_env / canary_additional_env."
  type = object({
    contract_apply_policy = optional(string, "Gate")
    backup_command        = optional(string)
    enforce               = optional(bool)
  })
  default = null

  validation {
    condition     = var.migration_safety == null ? true : contains(["Gate", "Auto"], var.migration_safety.contract_apply_policy)
    error_message = "migration_safety.contract_apply_policy must be Gate or Auto."
  }

  validation {
    condition     = var.migration_safety == null ? true : (var.migration_safety.backup_command == null ? true : trimspace(var.migration_safety.backup_command) != "")
    error_message = "migration_safety.backup_command must be null or a non-empty command."
  }
}

locals {
  migration_safety_environment = var.migration_safety == null ? {} : merge(
    { Database__MigrationSafety__ContractApplyPolicy = var.migration_safety.contract_apply_policy },
    var.migration_safety.backup_command == null ? {} : { Database__MigrationSafety__BackupCommand = var.migration_safety.backup_command },
    var.migration_safety.enforce == null ? {} : { Database__MigrationSafety__Enforce = tostring(var.migration_safety.enforce) }
  )
}

output "migration_safety_environment" {
  description = "Database:MigrationSafety keys rendered on the stable and canary task definitions. Empty means the server defaults apply."
  value       = local.migration_safety_environment
}
