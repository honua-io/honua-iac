provider "azurerm" {
  features {}
}

module "honua" {
  source = "../../modules/azure-aca"

  environment                     = var.environment
  name_prefix                     = var.name_prefix
  location                        = var.location
  image                           = var.honua_image
  admin_password                  = var.honua_admin_password
  db_admin_password               = var.db_admin_password
  existing_db_fqdn                = var.existing_db_fqdn
  existing_db_connection_string   = var.existing_db_connection_string
  db_firewall_start_ip            = var.db_firewall_start_ip
  db_firewall_end_ip              = var.db_firewall_end_ip
  db_geo_redundant_backup_enabled = var.db_geo_redundant_backup_enabled
  db_backup_retention_days        = var.db_backup_retention_days
  enable_postgis                  = var.enable_postgis
  postgis_readiness_max_attempts  = var.postgis_readiness_max_attempts
  postgis_readiness_sleep_seconds = var.postgis_readiness_sleep_seconds
  redis_enabled                   = var.redis_enabled
  redis_connection_string         = var.redis_connection_string
  redis_sku_name                  = var.redis_sku_name
  redis_family                    = var.redis_family
  redis_capacity                  = var.redis_capacity
  registry_server                 = var.registry_server
  registry_username               = var.registry_username
  registry_password               = var.registry_password
  min_replicas                    = var.min_replicas
  max_replicas                    = var.max_replicas
  key_vault_default_action        = var.key_vault_default_action
  tags                            = var.tags

  additional_env = {
    HONUA_SERVE_ADMIN_UI            = "true"
    HONUA_ADMIN_UI                  = "true"
    HostValidation__AllowedHosts__0 = "*.azurecontainerapps.io"
  }
}

locals {
  honua_url     = module.honua.container_app_fqdn != null ? "https://${module.honua.container_app_fqdn}" : null
  db_reused     = var.existing_db_fqdn != "" && var.existing_db_connection_string != ""
  cache_enabled = var.redis_enabled || var.redis_connection_string != ""
  cache_reused  = var.redis_connection_string != ""

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
      current_revision      = null
      desired_revision      = null
      current_image         = var.honua_image
      desired_image         = var.honua_image
    }
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
      admin_password_secret   = module.honua.admin_password_secret_id
      db_connection_secret    = module.honua.db_connection_secret_id
      redis_connection_secret = module.honua.redis_connection_secret_id
    }
    grouping = {
      environment    = var.environment
      name_prefix    = var.name_prefix
      resource_group = module.honua.resource_group_name
      tags           = var.tags
    }
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
