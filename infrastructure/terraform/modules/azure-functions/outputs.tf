# --- Infrastructure outputs ---

output "environment" {
  description = "Deployment environment label used for control-plane target IDs."
  value       = var.environment
}

output "function_app_name" {
  description = "Name of the primary Linux Function App."
  value       = azurerm_linux_function_app.this.name
}

output "function_app_id" {
  description = "Resource ID of the primary Linux Function App."
  value       = azurerm_linux_function_app.this.id
}

output "function_app_url" {
  description = "Primary HTTPS endpoint for the Function App."
  value       = "https://${azurerm_linux_function_app.this.default_hostname}"
}

output "function_app_slot_name" {
  description = "Name of the staging deployment slot when slot-based rollout is enabled."
  value       = var.deployment_slot_enabled ? azurerm_linux_function_app_slot.staging[0].name : null
}

output "function_app_slot_id" {
  description = "Resource ID of the staging deployment slot when slot-based rollout is enabled."
  value       = var.deployment_slot_enabled ? azurerm_linux_function_app_slot.staging[0].id : null
}

output "resource_group_name" {
  description = "Resource group containing the Function App deployment."
  value       = azurerm_resource_group.this.name
}

output "key_vault_id" {
  description = "Resource ID of the Key Vault storing runtime secrets."
  value       = azurerm_key_vault.this.id
}

output "db_fqdn" {
  description = "Database server FQDN used by the runtime."
  value       = local.db_server_fqdn
  sensitive   = true
}

output "db_connection_string" {
  description = "Resolved runtime PostgreSQL connection string."
  value       = local.db_connection_string
  sensitive   = true
}

output "db_connection_secret_id" {
  description = "Resource ID of the Key Vault secret storing the runtime database connection string."
  value       = azurerm_key_vault_secret.connection_string.id
}

output "admin_password_secret_id" {
  description = "Resource ID of the Key Vault secret storing the Honua admin password."
  value       = azurerm_key_vault_secret.admin_password.id
}

output "connection_encryption_master_key_secret_id" {
  description = "Resource ID of the Key Vault secret storing the connection encryption master key."
  value       = azurerm_key_vault_secret.connection_encryption_master_key.id
}

output "redis_connection_string" {
  description = "Resolved Redis connection string when Redis is enabled or reused."
  value       = local.redis_connection
  sensitive   = true
}

output "redis_connection_secret_id" {
  description = "Resource ID of the Key Vault secret storing the Redis connection string when Redis is enabled."
  value       = local.redis_connection != "" ? azurerm_key_vault_secret.redis_connection[0].id : null
  sensitive   = true
}

output "app_storage_enabled" {
  description = "Whether application blob storage is enabled."
  value       = var.app_storage_enabled
}

output "app_storage_account_name" {
  description = "Storage account name used for application blob storage when enabled."
  value       = var.app_storage_enabled ? azurerm_storage_account.app_storage[0].name : null
}

output "app_storage_account_id" {
  description = "Storage account resource ID used for application blob storage when enabled."
  value       = var.app_storage_enabled ? azurerm_storage_account.app_storage[0].id : null
}

output "app_storage_container_name" {
  description = "Blob container name used for application storage when enabled."
  value       = var.app_storage_enabled ? azurerm_storage_container.app_storage[0].name : null
}

# --- Honua control-plane outputs ---

output "control_plane_target_kind" {
  description = "Honua control-plane deploy target kind for this runtime."
  value       = "AzureFunctions"
}

output "control_plane_backend_name" {
  description = "Honua control-plane deploy backend name for Azure Functions."
  value       = "honua-gitops-azure-functions"
}

output "control_plane_contract_version" {
  description = "Schema version for the unified Honua control-plane contract."
  value       = "v2"
}

output "control_plane_target_id" {
  description = "Stable control-plane target identifier for the Function App."
  value       = azurerm_linux_function_app.this.name
}

output "control_plane_target_name" {
  description = "Human-readable control-plane target name."
  value       = azurerm_linux_function_app.this.name
}

output "control_plane_target_resource_id" {
  description = "Provider resource identifier for the active deploy target."
  value       = azurerm_linux_function_app.this.id
}

output "control_plane_target_resource_group" {
  description = "Resource group containing the control-plane target."
  value       = azurerm_resource_group.this.name
}

output "control_plane_telemetry_policy" {
  description = "Default Honua telemetry policy used for deploy health evaluation."
  value       = "honua-http"
}

output "control_plane_current_revision" {
  description = "Currently routed revision label when slot-based rollout is enabled."
  value       = var.deployment_slot_enabled ? "production" : null
}

output "control_plane_desired_revision" {
  description = "Desired revision label when slot-based rollout is enabled."
  value       = var.deployment_slot_enabled ? var.deployment_slot_name : null
}

output "control_plane_slot_name" {
  description = "Deployment slot name used for the desired revision when slot-based rollout is enabled."
  value       = var.deployment_slot_enabled ? azurerm_linux_function_app_slot.staging[0].name : null
}

output "control_plane_current_image" {
  description = "Current container image reference for the live workload."
  value       = var.image
}

output "control_plane_desired_image" {
  description = "Desired container image reference for the workload."
  value       = var.deployment_slot_enabled ? local.slot_image : var.image
}

output "marketplace_profile" {
  description = "Machine-readable marketplace deployment support profile."
  value = {
    schema_version  = "v1"
    eligible        = false
    turnkey_runtime = true
    bundle_profile  = "operator-only"
    target_family   = "azure-serverless"
    blocker_reason  = "Serverless runtime targets are excluded from marketplace-targeted bundles; prefer azure-aca."
  }
}

output "control_plane_contract" {
  description = "Unified control-plane contract for deploy automation and marketplace packaging."
  value = nonsensitive({
    schema_version = "v2"
    backend_name   = "honua-gitops-azure-functions"
    target_kind    = "AzureFunctions"
    target_id      = azurerm_linux_function_app.this.name
    target_name    = azurerm_linux_function_app.this.name
    resource_id    = azurerm_linux_function_app.this.id
    resource_group = azurerm_resource_group.this.name
    endpoint       = var.public_network_access_enabled ? "https://${azurerm_linux_function_app.this.default_hostname}" : null
    artifact_reference = {
      kind    = "container-image"
      current = var.image
      desired = var.deployment_slot_enabled ? local.slot_image : var.image
    }
    current_revision = var.deployment_slot_enabled ? "production" : null
    desired_revision = var.deployment_slot_enabled ? var.deployment_slot_name : null
    secret_refs = {
      secret_store = {
        kind           = "azure-key-vault"
        id             = azurerm_key_vault.this.id
        name           = azurerm_key_vault.this.name
        versionless_id = null
      }
      admin_password = {
        kind           = "azure-key-vault-secret"
        id             = azurerm_key_vault_secret.admin_password.id
        versionless_id = azurerm_key_vault_secret.admin_password.versionless_id
        name           = azurerm_key_vault_secret.admin_password.name
      }
      connection_encryption_master_key = {
        kind           = "azure-key-vault-secret"
        id             = azurerm_key_vault_secret.connection_encryption_master_key.id
        versionless_id = azurerm_key_vault_secret.connection_encryption_master_key.versionless_id
        name           = azurerm_key_vault_secret.connection_encryption_master_key.name
      }
      database_connection = {
        kind           = "azure-key-vault-secret"
        id             = azurerm_key_vault_secret.connection_string.id
        versionless_id = azurerm_key_vault_secret.connection_string.versionless_id
        name           = azurerm_key_vault_secret.connection_string.name
      }
      redis_connection = local.redis_connection != "" ? {
        kind           = "azure-key-vault-secret"
        id             = azurerm_key_vault_secret.redis_connection[0].id
        versionless_id = azurerm_key_vault_secret.redis_connection[0].versionless_id
        name           = azurerm_key_vault_secret.redis_connection[0].name
      } : null
      registry_pull = local.registry_auth_mode_resolved == "username_password" ? {
        kind           = "app-service-registry-credential"
        id             = null
        name           = local.registry_server_normalized
        versionless_id = null
      } : null
    }
    object_storage_refs = {
      enabled              = var.app_storage_enabled
      kind                 = "azure-blob"
      bucket_name          = null
      bucket_arn           = null
      prefix               = null
      storage_account_name = var.app_storage_enabled ? azurerm_storage_account.app_storage[0].name : null
      storage_account_id   = var.app_storage_enabled ? azurerm_storage_account.app_storage[0].id : null
      container_name       = var.app_storage_enabled ? azurerm_storage_container.app_storage[0].name : null
    }
    health_policy = {
      kind                      = "http-readiness"
      telemetry_policy          = "honua-http"
      readiness_path            = "/healthz/ready"
      stable_job                = null
      canary_job                = null
      progressive_delivery      = false
      slot_based                = var.deployment_slot_enabled
      current_slot              = var.deployment_slot_enabled ? "production" : null
      desired_slot              = var.deployment_slot_enabled ? var.deployment_slot_name : null
      verification_header_name  = null
      verification_header_value = null
    }
    target = {
      kind           = "AzureFunctions"
      backend_name   = "honua-gitops-azure-functions"
      id             = azurerm_linux_function_app.this.name
      name           = azurerm_linux_function_app.this.name
      resource_id    = azurerm_linux_function_app.this.id
      resource_group = azurerm_resource_group.this.name
      endpoint       = "https://${azurerm_linux_function_app.this.default_hostname}"
    }
    artifact = {
      kind    = "container-image"
      current = var.image
      desired = var.deployment_slot_enabled ? local.slot_image : var.image
    }
    rollout = {
      current_revision     = var.deployment_slot_enabled ? "production" : null
      desired_revision     = var.deployment_slot_enabled ? var.deployment_slot_name : null
      progressive_delivery = false
      slot_based           = var.deployment_slot_enabled
    }
    telemetry = {
      policy     = "honua-http"
      stable_job = null
      canary_job = null
    }
    capabilities = {
      object_storage = var.app_storage_enabled
      canary         = false
      slot           = var.deployment_slot_enabled
    }
    marketplace = {
      schema_version  = "v1"
      eligible        = false
      turnkey_runtime = true
      bundle_profile  = "operator-only"
      target_family   = "azure-serverless"
      blocker_reason  = "Serverless runtime targets are excluded from marketplace-targeted bundles; prefer azure-aca."
    }
  })
  sensitive = true
}

output "operations_metadata" {
  description = "Structured operational metadata for backup/restore and secret rotation runbooks."
  value = {
    workload = {
      kind                       = "function-app"
      resource_group             = azurerm_resource_group.this.name
      function_app_name          = azurerm_linux_function_app.this.name
      function_app_id            = azurerm_linux_function_app.this.id
      function_app_hostname      = azurerm_linux_function_app.this.default_hostname
      function_app_url           = "https://${azurerm_linux_function_app.this.default_hostname}"
      deployment_slot_enabled    = var.deployment_slot_enabled
      deployment_slot_name       = var.deployment_slot_enabled ? azurerm_linux_function_app_slot.staging[0].name : null
      deployment_slot_id         = var.deployment_slot_enabled ? azurerm_linux_function_app_slot.staging[0].id : null
      service_plan_name          = azurerm_service_plan.this.name
      service_plan_id            = azurerm_service_plan.this.id
      storage_account_name       = azurerm_storage_account.this.name
      storage_account_id         = azurerm_storage_account.this.id
      log_analytics_workspace_id = var.app_insights_enabled ? azurerm_log_analytics_workspace.this[0].id : null
      application_insights_id    = var.app_insights_enabled ? azurerm_application_insights.this[0].id : null
    }
    database = {
      reused                        = local.db_use_existing
      engine                        = "postgres"
      server_name                   = local.db_use_existing ? null : azurerm_postgresql_flexible_server.this[0].name
      server_id                     = local.db_use_existing ? null : azurerm_postgresql_flexible_server.this[0].id
      fqdn                          = local.db_server_fqdn
      database_name                 = var.db_name
      database_id                   = local.db_use_existing ? null : azurerm_postgresql_flexible_server_database.this[0].id
      admin_username                = var.db_admin_username
      port                          = 5432
      backup_retention_days         = local.db_use_existing ? null : var.db_backup_retention_days
      geo_redundant_backup_enabled  = local.db_use_existing ? null : var.db_geo_redundant_backup_enabled
      public_network_access_enabled = local.db_use_existing ? null : var.db_public_network_access
      firewall_rule_name            = length(azurerm_postgresql_flexible_server_firewall_rule.validation) > 0 ? azurerm_postgresql_flexible_server_firewall_rule.validation[0].name : null
      secret_ref = {
        id             = azurerm_key_vault_secret.connection_string.id
        versionless_id = azurerm_key_vault_secret.connection_string.versionless_id
        name           = azurerm_key_vault_secret.connection_string.name
      }
      postgis = {
        enabled                 = var.enable_postgis
        allowlist_configuration = local.db_use_existing ? null : (var.enable_postgis ? azurerm_postgresql_flexible_server_configuration.postgis[0].name : null)
        provisioner             = var.enable_postgis ? "postgresql_extension" : null
        readiness_max_attempts  = var.postgis_readiness_max_attempts
        readiness_sleep_seconds = var.postgis_readiness_sleep_seconds
        extensions              = ["postgis", "postgis_raster"]
      }
    }
    cache = {
      enabled     = local.redis_enabled
      reused      = local.redis_enabled && !local.redis_create
      name        = local.redis_create ? azurerm_redis_cache.this[0].name : null
      id          = local.redis_create ? azurerm_redis_cache.this[0].id : null
      hostname    = local.redis_create ? azurerm_redis_cache.this[0].hostname : null
      port        = local.redis_create ? azurerm_redis_cache.this[0].ssl_port : null
      minimum_tls = local.redis_create ? azurerm_redis_cache.this[0].minimum_tls_version : null
      secret_ref = local.redis_enabled ? {
        id             = azurerm_key_vault_secret.redis_connection[0].id
        versionless_id = azurerm_key_vault_secret.redis_connection[0].versionless_id
        name           = azurerm_key_vault_secret.redis_connection[0].name
      } : null
    }
    object_storage = {
      enabled              = var.app_storage_enabled
      kind                 = "azure-blob"
      storage_account_name = var.app_storage_enabled ? azurerm_storage_account.app_storage[0].name : null
      storage_account_id   = var.app_storage_enabled ? azurerm_storage_account.app_storage[0].id : null
      container_name       = var.app_storage_enabled ? azurerm_storage_container.app_storage[0].name : null
      principal_id         = azurerm_user_assigned_identity.function.principal_id
    }
    secret_store = {
      resource_group = azurerm_resource_group.this.name
      id             = azurerm_key_vault.this.id
      name           = azurerm_key_vault.this.name
      diagnostics = {
        enabled                    = var.key_vault_diagnostics_enabled
        diagnostic_setting_id      = var.key_vault_diagnostics_enabled && (trimspace(var.key_vault_diagnostics_workspace_id) != "" || var.app_insights_enabled) ? azurerm_monitor_diagnostic_setting.key_vault[0].id : null
        log_analytics_workspace_id = var.key_vault_diagnostics_enabled && (trimspace(var.key_vault_diagnostics_workspace_id) != "" || var.app_insights_enabled) ? local.key_vault_diagnostics_workspace_id : null
      }
    }
    secrets = {
      admin_password = {
        id             = azurerm_key_vault_secret.admin_password.id
        versionless_id = azurerm_key_vault_secret.admin_password.versionless_id
        name           = azurerm_key_vault_secret.admin_password.name
        expiration     = azurerm_key_vault_secret.admin_password.expiration_date
      }
      connection_encryption_master_key = {
        id             = azurerm_key_vault_secret.connection_encryption_master_key.id
        versionless_id = azurerm_key_vault_secret.connection_encryption_master_key.versionless_id
        name           = azurerm_key_vault_secret.connection_encryption_master_key.name
        expiration     = azurerm_key_vault_secret.connection_encryption_master_key.expiration_date
      }
      db_connection = {
        id             = azurerm_key_vault_secret.connection_string.id
        versionless_id = azurerm_key_vault_secret.connection_string.versionless_id
        name           = azurerm_key_vault_secret.connection_string.name
        expiration     = azurerm_key_vault_secret.connection_string.expiration_date
      }
      redis_connection = local.redis_enabled ? {
        id             = azurerm_key_vault_secret.redis_connection[0].id
        versionless_id = azurerm_key_vault_secret.redis_connection[0].versionless_id
        name           = azurerm_key_vault_secret.redis_connection[0].name
        expiration     = azurerm_key_vault_secret.redis_connection[0].expiration_date
      } : null
    }
  }
  sensitive = true
}
