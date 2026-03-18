# --- Infrastructure outputs ---

output "environment" {
  description = "Deployment environment label used for control-plane target IDs."
  value       = var.environment
}

output "container_app_name" {
  description = "Container App name."
  value       = azurerm_container_app.this.name
}

output "container_app_id" {
  description = "Container App resource ID."
  value       = azurerm_container_app.this.id
}

output "container_app_environment_id" {
  description = "Container Apps environment resource ID."
  value       = azurerm_container_app_environment.this.id
}

output "container_app_fqdn" {
  description = "Container App FQDN (if ingress enabled)."
  value       = try(azurerm_container_app.this.ingress[0].fqdn, null)
}

output "resource_group_name" {
  description = "Resource group name."
  value       = azurerm_resource_group.this.name
}

output "database_fqdn" {
  description = "PostgreSQL server FQDN."
  value       = local.db_server_fqdn
  sensitive   = true
}

output "key_vault_id" {
  description = "Key Vault resource ID."
  value       = azurerm_key_vault.this.id
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
  description = "Key Vault secret ID for the Redis connection string (if set)."
  value       = local.redis_connection != "" ? azurerm_key_vault_secret.redis_connection[0].id : null
  sensitive   = true
}

# --- Honua control-plane outputs ---

output "control_plane_target_kind" {
  description = "Honua control-plane deploy target kind for Azure Container Apps."
  value       = "AzureContainerApps"
}

output "control_plane_backend_name" {
  description = "Honua control-plane deploy backend name for Azure Container Apps GitOps."
  value       = "honua-gitops-azure-container-apps"
}

output "control_plane_target_id" {
  description = "Stable target id for Honua control-plane deploy operations."
  value       = azurerm_container_app.this.name
}

output "control_plane_target_name" {
  description = "Primary workload name used by the Honua deploy target."
  value       = azurerm_container_app.this.name
}

output "control_plane_target_resource_id" {
  description = "Stable Azure resource ID for the Honua deploy target."
  value       = azurerm_container_app.this.id
}

output "control_plane_target_resource_group" {
  description = "Stable Azure resource group for the Honua deploy target."
  value       = azurerm_resource_group.this.name
}

output "control_plane_telemetry_policy" {
  description = "Default Honua telemetry policy for Azure Container Apps deploy health evaluation."
  value       = "honua-http"
}

output "operations_metadata" {
  description = "Structured operational metadata for backup/restore and secret rotation runbooks."
  value = {
    workload = {
      kind                         = "container-app"
      resource_group               = azurerm_resource_group.this.name
      container_app_name           = azurerm_container_app.this.name
      container_app_id             = azurerm_container_app.this.id
      identity_id                  = azurerm_user_assigned_identity.this.id
      container_app_environment    = azurerm_container_app_environment.this.name
      container_app_environment_id = azurerm_container_app_environment.this.id
      fqdn                         = try(azurerm_container_app.this.ingress[0].fqdn, null)
      min_replicas                 = var.min_replicas
      max_replicas                 = var.max_replicas
      log_analytics_workspace_id   = var.log_analytics_enabled ? azurerm_log_analytics_workspace.this[0].id : null
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
        id             = azurerm_key_vault_secret.db_connection.id
        versionless_id = azurerm_key_vault_secret.db_connection.versionless_id
        name           = azurerm_key_vault_secret.db_connection.name
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
        id             = azurerm_key_vault_secret.db_connection.id
        versionless_id = azurerm_key_vault_secret.db_connection.versionless_id
        name           = azurerm_key_vault_secret.db_connection.name
        expiration     = azurerm_key_vault_secret.db_connection.expiration_date
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
