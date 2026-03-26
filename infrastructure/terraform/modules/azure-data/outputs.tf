# --- Infrastructure outputs ---

output "db_fqdn" {
  description = "PostgreSQL Flexible Server FQDN."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "db_connection_string" {
  description = "PostgreSQL connection string."
  value       = local.db_connection_string
  sensitive   = true
}

output "redis_connection_string" {
  description = "Redis primary connection string (empty if redis_enabled is false)."
  value       = local.redis_connection
  sensitive   = true
}

output "key_vault_id" {
  description = "Key Vault resource ID."
  value       = azurerm_key_vault.this.id
}

output "key_vault_name" {
  description = "Key Vault name."
  value       = azurerm_key_vault.this.name
}

output "db_connection_secret_id" {
  description = "Key Vault secret ID for the DB connection string."
  value       = azurerm_key_vault_secret.db_connection.id
}

output "admin_password_secret_id" {
  description = "Key Vault secret ID for the admin password."
  value       = azurerm_key_vault_secret.admin_password.id
}

output "redis_connection_secret_id" {
  description = "Key Vault secret ID for the Redis connection string (null if Redis is disabled)."
  value       = var.redis_enabled ? azurerm_key_vault_secret.redis_connection[0].id : null
  sensitive   = true
}

output "resource_group_name" {
  description = "Resource group name containing the data tier resources."
  value       = azurerm_resource_group.this.name
}

output "operations_metadata" {
  description = "Structured operational metadata for backup/restore and secret rotation runbooks."
  value = {
    database = {
      engine                        = "postgres"
      server_name                   = azurerm_postgresql_flexible_server.this.name
      server_id                     = azurerm_postgresql_flexible_server.this.id
      fqdn                          = azurerm_postgresql_flexible_server.this.fqdn
      database_name                 = azurerm_postgresql_flexible_server_database.this.name
      database_id                   = azurerm_postgresql_flexible_server_database.this.id
      admin_username                = var.db_admin_username
      port                          = 5432
      backup_retention_days         = var.db_backup_retention_days
      geo_redundant_backup_enabled  = var.db_geo_redundant_backup_enabled
      public_network_access_enabled = var.db_public_network_access
      secret_ref = {
        id             = azurerm_key_vault_secret.db_connection.id
        versionless_id = azurerm_key_vault_secret.db_connection.versionless_id
        name           = azurerm_key_vault_secret.db_connection.name
      }
      postgis = {
        enabled                 = var.enable_postgis
        allowlist_configuration = var.enable_postgis ? azurerm_postgresql_flexible_server_configuration.postgis[0].name : null
        provisioner             = var.enable_postgis ? "postgresql_extension" : null
        readiness_max_attempts  = var.postgis_readiness_max_attempts
        readiness_sleep_seconds = var.postgis_readiness_sleep_seconds
        extensions              = ["postgis", "postgis_raster"]
      }
    }
    cache = {
      enabled     = var.redis_enabled
      name        = var.redis_enabled ? azurerm_redis_cache.this[0].name : null
      id          = var.redis_enabled ? azurerm_redis_cache.this[0].id : null
      hostname    = var.redis_enabled ? azurerm_redis_cache.this[0].hostname : null
      port        = var.redis_enabled ? azurerm_redis_cache.this[0].ssl_port : null
      minimum_tls = var.redis_enabled ? azurerm_redis_cache.this[0].minimum_tls_version : null
      secret_ref = var.redis_enabled ? {
        id             = azurerm_key_vault_secret.redis_connection[0].id
        versionless_id = azurerm_key_vault_secret.redis_connection[0].versionless_id
        name           = azurerm_key_vault_secret.redis_connection[0].name
      } : null
    }
    secret_store = {
      resource_group = azurerm_resource_group.this.name
      id             = azurerm_key_vault.this.id
      name           = azurerm_key_vault.this.name
      diagnostics = {
        enabled                    = var.key_vault_diagnostics_enabled
        diagnostic_setting_id      = var.key_vault_diagnostics_enabled ? azurerm_monitor_diagnostic_setting.key_vault[0].id : null
        log_analytics_workspace_id = var.key_vault_diagnostics_enabled ? local.key_vault_diagnostics_workspace_id : null
      }
    }
    secrets = {
      admin_password = {
        id             = azurerm_key_vault_secret.admin_password.id
        versionless_id = azurerm_key_vault_secret.admin_password.versionless_id
        name           = azurerm_key_vault_secret.admin_password.name
        expiration     = azurerm_key_vault_secret.admin_password.expiration_date
      }
      db_connection = {
        id             = azurerm_key_vault_secret.db_connection.id
        versionless_id = azurerm_key_vault_secret.db_connection.versionless_id
        name           = azurerm_key_vault_secret.db_connection.name
        expiration     = azurerm_key_vault_secret.db_connection.expiration_date
      }
      redis_connection = var.redis_enabled ? {
        id             = azurerm_key_vault_secret.redis_connection[0].id
        versionless_id = azurerm_key_vault_secret.redis_connection[0].versionless_id
        name           = azurerm_key_vault_secret.redis_connection[0].name
        expiration     = azurerm_key_vault_secret.redis_connection[0].expiration_date
      } : null
    }
  }
  sensitive = true
}
