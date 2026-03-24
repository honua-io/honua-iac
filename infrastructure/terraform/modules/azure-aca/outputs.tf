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

output "connection_encryption_master_key_secret_id" {
  description = "Key Vault secret ID for the connection encryption master key."
  value       = azurerm_key_vault_secret.connection_encryption_master_key.id
}

output "redis_connection_secret_id" {
  description = "Key Vault secret ID for the Redis connection string (if set)."
  value       = local.redis_connection != "" ? azurerm_key_vault_secret.redis_connection[0].id : null
  sensitive   = true
}

output "app_storage_enabled" {
  description = "Whether application Blob storage is enabled."
  value       = var.app_storage_enabled
}

output "app_storage_account_name" {
  description = "Application Blob storage account name when enabled."
  value       = var.app_storage_enabled ? azurerm_storage_account.app_storage[0].name : null
}

output "app_storage_account_id" {
  description = "Application Blob storage account resource ID when enabled."
  value       = var.app_storage_enabled ? azurerm_storage_account.app_storage[0].id : null
}

output "app_storage_container_name" {
  description = "Application Blob container name when enabled."
  value       = var.app_storage_enabled ? azurerm_storage_container.app_storage[0].name : null
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

output "control_plane_contract_version" {
  description = "Schema version for the unified Honua control-plane contract."
  value       = "v2"
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

output "control_plane_current_revision" {
  description = "Current stable workload revision identifier."
  value       = azurerm_container_app.this.latest_revision_name
}

output "control_plane_desired_revision" {
  description = "Desired workload revision identifier for deploy orchestration."
  value       = azurerm_container_app.this.latest_revision_name
}

output "control_plane_current_image" {
  description = "Current stable artifact reference used by the deploy target."
  value       = var.image
}

output "control_plane_desired_image" {
  description = "Desired artifact reference used by the deploy target."
  value       = var.image
}

output "marketplace_profile" {
  description = "Machine-readable marketplace deployment support profile."
  value = {
    schema_version  = "v1"
    eligible        = true
    turnkey_runtime = true
    bundle_profile  = "marketplace-turnkey"
    target_family   = "azure-container-runtime"
    blocker_reason  = null
  }
}

output "control_plane_contract" {
  description = "Unified control-plane contract for deploy automation and marketplace packaging."
  value = nonsensitive({
    schema_version = "v2"
    backend_name   = "honua-gitops-azure-container-apps"
    target_kind    = "AzureContainerApps"
    target_id      = azurerm_container_app.this.name
    target_name    = azurerm_container_app.this.name
    resource_id    = azurerm_container_app.this.id
    resource_group = azurerm_resource_group.this.name
    endpoint       = try(azurerm_container_app.this.ingress[0].fqdn, null) != null ? "https://${azurerm_container_app.this.ingress[0].fqdn}" : null
    artifact_reference = {
      kind    = "container-image"
      current = var.image
      desired = var.image
    }
    current_revision = azurerm_container_app.this.latest_revision_name
    desired_revision = azurerm_container_app.this.latest_revision_name
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
        id             = azurerm_key_vault_secret.db_connection.id
        versionless_id = azurerm_key_vault_secret.db_connection.versionless_id
        name           = azurerm_key_vault_secret.db_connection.name
      }
      redis_connection = local.redis_connection != "" ? {
        kind           = "azure-key-vault-secret"
        id             = azurerm_key_vault_secret.redis_connection[0].id
        versionless_id = azurerm_key_vault_secret.redis_connection[0].versionless_id
        name           = azurerm_key_vault_secret.redis_connection[0].name
      } : null
      registry_pull = local.registry_auth_mode_resolved == "username_password" ? {
        kind           = "container-app-secret"
        id             = null
        name           = "registry-password"
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
      slot_based                = false
      current_slot              = null
      desired_slot              = null
      verification_header_name  = null
      verification_header_value = null
    }
    target = {
      kind           = "AzureContainerApps"
      backend_name   = "honua-gitops-azure-container-apps"
      id             = azurerm_container_app.this.name
      name           = azurerm_container_app.this.name
      resource_id    = azurerm_container_app.this.id
      resource_group = azurerm_resource_group.this.name
      endpoint       = try(azurerm_container_app.this.ingress[0].fqdn, null) != null ? "https://${azurerm_container_app.this.ingress[0].fqdn}" : null
    }
    artifact = {
      kind    = "container-image"
      current = var.image
      desired = var.image
    }
    rollout = {
      current_revision     = azurerm_container_app.this.latest_revision_name
      desired_revision     = azurerm_container_app.this.latest_revision_name
      progressive_delivery = false
      slot_based           = false
    }
    telemetry = {
      policy     = "honua-http"
      stable_job = null
      canary_job = null
    }
    capabilities = {
      object_storage = var.app_storage_enabled
      canary         = false
      slot           = false
    }
    marketplace = {
      schema_version  = "v1"
      eligible        = true
      turnkey_runtime = true
      bundle_profile  = "marketplace-turnkey"
      target_family   = "azure-container-runtime"
      blocker_reason  = null
    }
  })
  sensitive = true
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
    object_storage = {
      enabled              = var.app_storage_enabled
      kind                 = "azure-blob"
      storage_account_name = var.app_storage_enabled ? azurerm_storage_account.app_storage[0].name : null
      storage_account_id   = var.app_storage_enabled ? azurerm_storage_account.app_storage[0].id : null
      container_name       = var.app_storage_enabled ? azurerm_storage_container.app_storage[0].name : null
      principal_id         = azurerm_user_assigned_identity.this.principal_id
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
      connection_encryption_master_key = {
        id             = azurerm_key_vault_secret.connection_encryption_master_key.id
        versionless_id = azurerm_key_vault_secret.connection_encryption_master_key.versionless_id
        name           = azurerm_key_vault_secret.connection_encryption_master_key.name
        expiration     = azurerm_key_vault_secret.connection_encryption_master_key.expiration_date
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
