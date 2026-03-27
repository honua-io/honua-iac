provider "azurerm" {
  features {}
}

module "honua" {
  source = "../../modules/azure-aca"

  environment                             = var.environment
  name_prefix                             = var.name_prefix
  location                                = var.location
  image                                   = local.install_artifact_image
  container_port                          = var.container_port
  container_cpu                           = var.container_cpu
  container_memory                        = var.container_memory
  admin_password                          = var.honua_admin_password
  connection_encryption_master_key        = var.connection_encryption_master_key
  db_admin_password                       = var.db_admin_password
  existing_db_fqdn                        = local.install_database_host
  existing_db_connection_string           = var.existing_db_connection_string
  db_sku_name                             = local.install_database_compute_sku
  db_storage_mb                           = local.install_database_storage_mb
  db_public_network_access                = local.install_database_public_access
  db_firewall_start_ip                    = local.install_network_firewall_start_ip
  db_firewall_end_ip                      = local.install_network_firewall_end_ip
  db_geo_redundant_backup_enabled         = var.db_geo_redundant_backup_enabled
  db_backup_retention_days                = var.db_backup_retention_days
  enable_postgis                          = local.install_database_postgis_enabled
  postgis_readiness_max_attempts          = local.install_database_readiness_max_attempts
  postgis_readiness_sleep_seconds         = local.install_database_readiness_sleep_seconds
  redis_enabled                           = local.install_redis_enabled
  redis_connection_string                 = var.redis_connection_string
  redis_sku_name                          = var.redis_sku_name
  redis_family                            = var.redis_family
  redis_capacity                          = var.redis_capacity
  registry_server                         = local.install_registry_server
  registry_auth_mode                      = local.install_registry_auth_mode
  registry_resource_id                    = local.install_registry_resource_id
  registry_username                       = var.registry_username
  registry_password                       = var.registry_password
  min_replicas                            = var.min_replicas
  max_replicas                            = var.max_replicas
  scaling_concurrent_requests             = var.scaling_concurrent_requests
  enable_ingress                          = local.install_enable_ingress
  ingress_allowed_cidrs                   = local.install_public_ingress_cidrs
  app_storage_enabled                     = local.install_storage_enabled
  app_storage_ip_rules                    = var.app_storage_ip_rules
  app_storage_container_name              = local.install_storage_name
  key_vault_purge_protection_enabled      = var.key_vault_purge_protection_enabled
  key_vault_public_network_access_enabled = var.key_vault_public_network_access_enabled
  key_vault_default_action                = var.key_vault_default_action
  key_vault_bypass                        = var.key_vault_bypass
  key_vault_ip_rules                      = var.key_vault_ip_rules
  key_vault_soft_delete_retention_days    = var.key_vault_soft_delete_retention_days
  secret_expiration_days                  = var.secret_expiration_days
  tags                                    = var.tags

  additional_env = {
    HONUA_SERVE_ADMIN_UI            = "true"
    HONUA_ADMIN_UI                  = "true"
    HostValidation__AllowedHosts__0 = "*.azurecontainerapps.io"
  }
}

locals {
  install_artifact_image                   = try(var.install.artifact.image, null) != null ? trimspace(var.install.artifact.image) : (var.honua_image != null ? trimspace(var.honua_image) : null)
  install_registry_server                  = try(var.install.artifact.registry.server, null) != null ? trimspace(var.install.artifact.registry.server) : var.registry_server
  install_registry_auth_mode               = try(var.install.artifact.registry.auth_mode, null) != null ? var.install.artifact.registry.auth_mode : var.registry_auth_mode
  install_registry_resource_id             = try(var.install.artifact.registry.resource_id, null) != null ? trimspace(var.install.artifact.registry.resource_id) : var.registry_resource_id
  install_database_host                    = try(var.install.database.host, null) != null ? trimspace(var.install.database.host) : var.existing_db_fqdn
  install_database_compute_sku             = try(var.install.database.compute_sku, null) != null ? var.install.database.compute_sku : var.db_sku_name
  install_database_storage_mb              = try(var.install.database.storage_mb, null) != null ? var.install.database.storage_mb : var.db_storage_mb
  install_database_postgis_enabled         = try(var.install.database.postgis_enabled, null) != null ? var.install.database.postgis_enabled : var.enable_postgis
  install_database_readiness_max_attempts  = try(var.install.database.readiness_max_attempts, null) != null ? var.install.database.readiness_max_attempts : var.postgis_readiness_max_attempts
  install_database_readiness_sleep_seconds = try(var.install.database.readiness_sleep_seconds, null) != null ? var.install.database.readiness_sleep_seconds : var.postgis_readiness_sleep_seconds
  install_database_public_access           = try(var.install.database.public_access, null) != null ? var.install.database.public_access : var.db_public_network_access
  install_redis_enabled                    = trimspace(var.redis_connection_string) != "" ? false : var.redis_enabled
  install_network_firewall_start_ip        = try(var.install.network.firewall_start_ip, null) != null ? trimspace(var.install.network.firewall_start_ip) : var.db_firewall_start_ip
  install_network_firewall_end_ip          = try(var.install.network.firewall_end_ip, null) != null ? trimspace(var.install.network.firewall_end_ip) : var.db_firewall_end_ip
  install_public_ingress_cidrs             = try(var.install.network.public_ingress_cidrs, null) != null ? var.install.network.public_ingress_cidrs : var.ingress_allowed_cidrs
  install_enable_ingress                   = try(var.install.network.public_ingress_cidrs, null) != null ? length(var.install.network.public_ingress_cidrs) > 0 : var.enable_ingress
  install_storage_enabled                  = try(var.install.storage.enabled, null) != null ? var.install.storage.enabled : var.app_storage_enabled
  install_storage_name                     = try(var.install.storage.container_name, null) != null ? trimspace(var.install.storage.container_name) : (try(var.install.storage.name, null) != null ? trimspace(var.install.storage.name) : var.app_storage_container_name)
  honua_url                                = module.honua.container_app_fqdn != null ? "https://${module.honua.container_app_fqdn}" : null
  db_reused                                = local.install_database_host != "" && var.existing_db_connection_string != ""
  cache_enabled                            = local.install_redis_enabled || var.redis_connection_string != ""
  cache_reused                             = var.redis_connection_string != ""

  install_contract = {
    schema_version = "v1"
    artifact = {
      image = local.install_artifact_image
      registry = {
        server      = local.install_registry_server != "" ? local.install_registry_server : null
        auth_mode   = local.install_registry_auth_mode
        resource_id = local.install_registry_resource_id != "" ? local.install_registry_resource_id : null
      }
    }
    database = {
      host                    = local.install_database_host != "" ? local.install_database_host : null
      connection_reused       = nonsensitive(var.existing_db_connection_string != "")
      compute_sku             = local.install_database_compute_sku
      storage_gb              = null
      storage_mb              = local.install_database_storage_mb
      public_access           = local.install_database_public_access
      postgis_enabled         = local.install_database_postgis_enabled
      readiness_max_attempts  = local.install_database_readiness_max_attempts
      readiness_sleep_seconds = local.install_database_readiness_sleep_seconds
    }
    network = {
      id                   = null
      cidr                 = null
      public_subnet_ids    = []
      private_subnet_ids   = []
      public_ingress_cidrs = length(local.install_public_ingress_cidrs) > 0 ? local.install_public_ingress_cidrs : null
      http_ingress_cidrs   = null
      https_ingress_cidrs  = null
      firewall_start_ip    = local.install_network_firewall_start_ip != "" ? local.install_network_firewall_start_ip : null
      firewall_end_ip      = local.install_network_firewall_end_ip != "" ? local.install_network_firewall_end_ip : null
    }
    storage = {
      enabled        = local.install_storage_enabled
      name           = local.install_storage_name != "" ? local.install_storage_name : null
      container_name = local.install_storage_name != "" ? local.install_storage_name : null
      prefix         = null
      force_destroy  = null
    }
  }

  deployment_contract = {
    schema_version = "v1"
    stack = {
      id          = "azure-aca"
      platform    = "azure-container-apps"
      runtime     = "container"
      environment = var.environment
      region      = var.location
    }
    endpoints = {
      public_base_url = local.honua_url
      readiness_url   = local.honua_url != null ? "${local.honua_url}/healthz/ready" : null
      admin_url       = local.honua_url != null ? "${local.honua_url}/api/v1/admin" : null
      protocol_url    = local.honua_url != null ? "${local.honua_url}/v1" : null
    }
    workload = {
      kind        = module.honua.control_plane_target_kind
      name        = module.honua.container_app_name
      resource_id = module.honua.container_app_id
    }
    rollout = {
      backend_name          = module.honua.control_plane_backend_name
      target_id             = module.honua.control_plane_target_id
      target_name           = module.honua.control_plane_target_name
      target_resource_id    = module.honua.control_plane_target_resource_id
      target_resource_group = module.honua.control_plane_target_resource_group
      current_revision      = module.honua.control_plane_current_revision
      desired_revision      = module.honua.control_plane_desired_revision
      current_image         = module.honua.control_plane_current_image
      desired_image         = module.honua.control_plane_desired_image
    }
    deploy = module.honua.control_plane_contract
    dependencies = {
      database = {
        kind       = "azure-postgres"
        host       = module.honua.database_fqdn
        reused     = local.db_reused
        secret_ref = module.honua.db_connection_secret_id
      }
      cache = {
        kind       = "azure-redis"
        enabled    = local.cache_enabled
        reused     = local.cache_reused
        host       = null
        secret_ref = module.honua.redis_connection_secret_id
      }
      secret_store = {
        kind = "azure-key-vault"
        id   = module.honua.key_vault_id
      }
      object_storage = {
        kind           = "azure-blob"
        enabled        = module.honua.app_storage_enabled
        account_name   = module.honua.app_storage_account_name
        container_name = module.honua.app_storage_container_name
      }
    }
  }

  validation_contract = {
    schema_version = "v1"
    platform = {
      name = "azure-container-apps"
      capabilities = {
        deploy_plan     = false
        mutation        = false
        scale_check     = true
        backup_drill    = true
        idempotency     = true
        protocol_checks = true
        object_storage  = module.honua.app_storage_enabled
      }
    }
    tests = {
      base_url      = local.honua_url
      readiness_url = local.honua_url != null ? "${local.honua_url}/healthz/ready" : null
      admin_url     = local.honua_url != null ? "${local.honua_url}/api/v1/admin" : null
      protocol_url  = local.honua_url != null ? "${local.honua_url}/v1" : null
    }
    artifacts = {
      terraform_root = path.cwd
      workload_name  = module.honua.container_app_name
      resource_group = module.honua.resource_group_name
      region         = var.location
    }
    lifecycle = {
      reuse_data_stack = local.db_reused
      destroy_mode     = "explicit"
    }
  }

  operations_contract = {
    schema_version = "v1"
    observability = {
      telemetry_policy      = module.honua.control_plane_telemetry_policy
      prometheus_job        = null
      prometheus_canary_job = null
      grafana_url           = null
    }
    runbooks = module.honua.operations_metadata
    secrets = {
      secret_store = {
        kind = "azure-key-vault"
        id   = module.honua.key_vault_id
      }
      admin_password_secret                   = module.honua.admin_password_secret_id
      connection_encryption_master_key_secret = module.honua.connection_encryption_master_key_secret_id
      db_connection_secret                    = module.honua.db_connection_secret_id
      redis_connection_secret                 = module.honua.redis_connection_secret_id
    }
    grouping = {
      environment    = var.environment
      name_prefix    = var.name_prefix
      resource_group = module.honua.resource_group_name
      tags           = var.tags
    }
  }
}

check "install_artifact_image_required" {
  assert {
    condition     = local.install_artifact_image != null && local.install_artifact_image != ""
    error_message = "Set install.artifact.image or honua_image."
  }
}

output "honua_url" {
  value = local.honua_url
}

output "deployment_contract" {
  description = "Stable deployment contract for validation and operator automation."
  value       = local.deployment_contract
  sensitive   = true
}

output "install_contract" {
  description = "Provider-neutral install contract for marketplace questionnaires and bundle automation."
  value       = local.install_contract
}

output "deploy_contract" {
  description = "Uniform deploy contract for marketplace automation."
  value       = module.honua.control_plane_contract
  sensitive   = true
}

output "validation_contract" {
  description = "Stable validation contract for scenario orchestration."
  value       = local.validation_contract
  sensitive   = true
}

output "operations_contract" {
  description = "Stable operations contract for day-2 metadata and secret references."
  value       = local.operations_contract
  sensitive   = true
}

output "operations_metadata" {
  description = "Structured operational metadata for backup/restore and secret rotation runbooks."
  value       = module.honua.operations_metadata
  sensitive   = true
}

output "app_storage_enabled" {
  value = module.honua.app_storage_enabled
}

output "app_storage_account_name" {
  value = module.honua.app_storage_account_name
}

output "app_storage_account_id" {
  value = module.honua.app_storage_account_id
}

output "app_storage_container_name" {
  value = module.honua.app_storage_container_name
}

output "environment" {
  value = module.honua.environment
}

output "container_app_name" {
  value = module.honua.container_app_name
}

output "container_app_id" {
  value = module.honua.container_app_id
}

output "container_app_environment_id" {
  value = module.honua.container_app_environment_id
}

output "control_plane_target_kind" {
  value = module.honua.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.honua.control_plane_backend_name
}

output "control_plane_target_id" {
  value = module.honua.control_plane_target_id
}

output "control_plane_target_name" {
  value = module.honua.control_plane_target_name
}

output "control_plane_target_resource_id" {
  value = module.honua.control_plane_target_resource_id
}

output "control_plane_target_resource_group" {
  value = module.honua.control_plane_target_resource_group
}

output "control_plane_telemetry_policy" {
  value = module.honua.control_plane_telemetry_policy
}

output "database_fqdn" {
  value     = module.honua.database_fqdn
  sensitive = true
}

output "resource_group_name" {
  value = module.honua.resource_group_name
}
