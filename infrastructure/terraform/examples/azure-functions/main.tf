provider "azurerm" {
  features {}
}

module "honua" {
  source = "../../modules/azure-functions"

  environment                     = var.environment
  name_prefix                     = var.name_prefix
  location                        = var.location
  image                           = var.honua_image
  deployment_slot_enabled         = var.deployment_slot_enabled
  deployment_slot_name            = var.deployment_slot_name
  deployment_slot_image           = var.deployment_slot_image
  admin_password                  = var.honua_admin_password
  plan_sku_name                   = var.plan_sku_name
  db_admin_password               = var.db_admin_password
  existing_db_fqdn                = var.existing_db_fqdn
  existing_db_connection_string   = var.existing_db_connection_string
  db_firewall_start_ip            = var.db_firewall_start_ip
  db_firewall_end_ip              = var.db_firewall_end_ip
  db_geo_redundant_backup_enabled = var.db_geo_redundant_backup_enabled
  db_backup_retention_days        = var.db_backup_retention_days
  enable_postgis                  = var.enable_postgis
  redis_enabled                   = var.redis_enabled
  redis_connection_string         = var.redis_connection_string
  redis_sku_name                  = var.redis_sku_name
  redis_family                    = var.redis_family
  redis_capacity                  = var.redis_capacity
  skip_migrations                 = var.skip_migrations
  tags                            = var.tags

  additional_env = {
    HONUA_SERVE_ADMIN_UI            = "true"
    HONUA_ADMIN_UI                  = "true"
    HostValidation__AllowedHosts__0 = "*.azurewebsites.net"
  }
}

locals {
  honua_url     = module.honua.function_app_url
  db_reused     = var.existing_db_fqdn != "" && var.existing_db_connection_string != ""
  cache_enabled = var.redis_enabled || var.redis_connection_string != ""
  cache_reused  = var.redis_connection_string != ""

  deployment_contract = {
    schema_version = "v1"
    stack = {
      id          = "azure-functions"
      platform    = "azure-functions"
      runtime     = "serverless"
      environment = var.environment
      region      = var.location
    }
    endpoints = {
      public_base_url = local.honua_url
      readiness_url   = "${local.honua_url}/healthz/ready"
      admin_url       = "${local.honua_url}/api/v1/admin"
      protocol_url    = "${local.honua_url}/v1"
    }
    workload = {
      kind        = module.honua.control_plane_target_kind
      name        = module.honua.function_app_name
      resource_id = module.honua.function_app_id
      slot_name   = module.honua.function_app_slot_name
      slot_id     = module.honua.function_app_slot_id
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
      slot_name             = module.honua.control_plane_slot_name
    }
    dependencies = {
      database = {
        kind       = "azure-postgres"
        host       = module.honua.db_fqdn
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
      name = "azure-functions"
      capabilities = {
        deploy_plan     = var.deployment_slot_enabled
        mutation        = false
        scale_check     = false
        backup_drill    = true
        idempotency     = true
        protocol_checks = true
      }
    }
    tests = {
      base_url      = local.honua_url
      readiness_url = "${local.honua_url}/healthz/ready"
      admin_url     = "${local.honua_url}/api/v1/admin"
      protocol_url  = "${local.honua_url}/v1"
    }
    artifacts = {
      terraform_root = path.cwd
      workload_name  = module.honua.function_app_name
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

output "environment" {
  value = module.honua.environment
}

output "function_app_name" {
  value = module.honua.function_app_name
}

output "function_app_id" {
  value = module.honua.function_app_id
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

output "control_plane_current_revision" {
  value = module.honua.control_plane_current_revision
}

output "control_plane_desired_revision" {
  value = module.honua.control_plane_desired_revision
}

output "control_plane_slot_name" {
  value = module.honua.control_plane_slot_name
}

output "control_plane_current_image" {
  value = module.honua.control_plane_current_image
}

output "control_plane_desired_image" {
  value = module.honua.control_plane_desired_image
}

output "function_app_slot_name" {
  value = module.honua.function_app_slot_name
}

output "function_app_slot_id" {
  value = module.honua.function_app_slot_id
}

output "db_fqdn" {
  value     = module.honua.db_fqdn
  sensitive = true
}

output "resource_group_name" {
  value = module.honua.resource_group_name
}
