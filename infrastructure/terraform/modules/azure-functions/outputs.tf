# --- Infrastructure outputs ---

output "environment" {
  value = var.environment
}

output "function_app_name" {
  value = azurerm_linux_function_app.this.name
}

output "function_app_id" {
  value = azurerm_linux_function_app.this.id
}

output "function_app_url" {
  value = "https://${azurerm_linux_function_app.this.default_hostname}"
}

output "function_app_slot_name" {
  value = var.deployment_slot_enabled ? azurerm_linux_function_app_slot.staging[0].name : null
}

output "function_app_slot_id" {
  value = var.deployment_slot_enabled ? azurerm_linux_function_app_slot.staging[0].id : null
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "key_vault_id" {
  value = azurerm_key_vault.this.id
}

output "db_fqdn" {
  value     = local.db_server_fqdn
  sensitive = true
}

output "db_connection_string" {
  value     = local.db_connection_string
  sensitive = true
}

output "db_connection_secret_id" {
  value = azurerm_key_vault_secret.connection_string.id
}

output "admin_password_secret_id" {
  value = azurerm_key_vault_secret.admin_password.id
}

output "redis_connection_string" {
  value     = local.redis_connection
  sensitive = true
}

output "redis_connection_secret_id" {
  value     = local.redis_connection != "" ? azurerm_key_vault_secret.redis_connection[0].id : null
  sensitive = true
}

# --- Honua control-plane outputs ---

output "control_plane_target_kind" {
  value = "AzureFunctions"
}

output "control_plane_backend_name" {
  value = "honua-gitops-azure-functions"
}

output "control_plane_target_id" {
  value = azurerm_linux_function_app.this.name
}

output "control_plane_target_name" {
  value = azurerm_linux_function_app.this.name
}

output "control_plane_target_resource_id" {
  value = azurerm_linux_function_app.this.id
}

output "control_plane_target_resource_group" {
  value = azurerm_resource_group.this.name
}

output "control_plane_telemetry_policy" {
  value = "honua-http"
}

output "control_plane_current_revision" {
  value = var.deployment_slot_enabled ? "production" : null
}

output "control_plane_desired_revision" {
  value = var.deployment_slot_enabled ? var.deployment_slot_name : null
}

output "control_plane_slot_name" {
  value = var.deployment_slot_enabled ? azurerm_linux_function_app_slot.staging[0].name : null
}

output "control_plane_current_image" {
  value = var.image
}

output "control_plane_desired_image" {
  value = var.deployment_slot_enabled ? local.slot_image : null
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
    secret_store = {
      resource_group = azurerm_resource_group.this.name
      id             = azurerm_key_vault.this.id
      name           = azurerm_key_vault.this.name
    }
    secrets = {
      admin_password = {
        id             = azurerm_key_vault_secret.admin_password.id
        versionless_id = azurerm_key_vault_secret.admin_password.versionless_id
        name           = azurerm_key_vault_secret.admin_password.name
        expiration     = azurerm_key_vault_secret.admin_password.expiration_date
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
