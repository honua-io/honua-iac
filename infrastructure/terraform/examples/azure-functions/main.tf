provider "azurerm" {
  features {}
}

module "honua" {
  source = "../../modules/azure-functions"

  environment                             = var.environment
  name_prefix                             = var.name_prefix
  location                                = var.location
  image                                   = var.honua_image
  deployment_slot_enabled                 = var.deployment_slot_enabled
  deployment_slot_name                    = var.deployment_slot_name
  deployment_slot_image                   = var.deployment_slot_image
  admin_password                          = var.honua_admin_password
  plan_sku_name                           = var.plan_sku_name
  db_admin_password                       = var.db_admin_password
  existing_db_fqdn                        = var.existing_db_fqdn
  existing_db_connection_string           = var.existing_db_connection_string
  db_firewall_start_ip                    = var.db_firewall_start_ip
  db_firewall_end_ip                      = var.db_firewall_end_ip
  db_geo_redundant_backup_enabled         = var.db_geo_redundant_backup_enabled
  db_backup_retention_days                = var.db_backup_retention_days
  enable_postgis                          = var.enable_postgis
  redis_enabled                           = var.redis_enabled
  redis_connection_string                 = var.redis_connection_string
  redis_sku_name                          = var.redis_sku_name
  redis_family                            = var.redis_family
  redis_capacity                          = var.redis_capacity
  key_vault_public_network_access_enabled = var.key_vault_public_network_access_enabled
  storage_network_default_action          = var.storage_network_default_action
  registry_server                         = var.registry_server
  registry_username                       = var.registry_username
  registry_password                       = var.registry_password
  skip_migrations                         = var.skip_migrations
  tags                                    = var.tags

  additional_env = {
    HONUA_SERVE_ADMIN_UI            = "true"
    HONUA_ADMIN_UI                  = "true"
    HostValidation__AllowedHosts__0 = "*.azurewebsites.net"
  }
}

locals {
  deployment_contract = {
    schema_version = "v1"
    stack = {
      id          = "azure-functions"
      platform    = "azure-functions"
      runtime     = "serverless"
      environment = module.honua.environment
      region      = var.location
    }
    endpoints = {
      public_base_url = module.honua.function_app_url
      readiness_path  = "/healthz/ready"
      liveness_path   = "/healthz/live"
      admin_base_path = "/api/v1/admin"
      openapi_path    = "/openapi.json"
    }
    workload = {
      kind           = module.honua.control_plane_target_kind
      name           = module.honua.function_app_name
      resource_id    = module.honua.function_app_id
      resource_group = module.honua.resource_group_name
    }
    rollout = {
      backend_name          = module.honua.control_plane_backend_name
      target_id             = module.honua.control_plane_target_id
      target_name           = module.honua.control_plane_target_name
      target_resource_id    = module.honua.control_plane_target_resource_id
      target_resource_group = module.honua.control_plane_target_resource_group
      current_revision      = module.honua.control_plane_current_revision
      desired_revision      = module.honua.control_plane_desired_revision
      slot_name             = module.honua.control_plane_slot_name
      current_image         = module.honua.control_plane_current_image
      desired_image         = module.honua.control_plane_desired_image
    }
    dependencies = {
      database = {
        provider = "azure"
        kind     = "postgresql-flexible-server"
        managed  = var.existing_db_fqdn == "" && nonsensitive(var.existing_db_connection_string) == ""
      }
      cache = {
        provider = "azure"
        kind     = "redis"
        enabled  = var.redis_enabled
        managed  = nonsensitive(var.redis_connection_string) == ""
      }
    }
  }

  validation_contract = {
    schema_version = "v1"
    platform = {
      name = "azure-functions"
      capabilities = {
        deploy_plan = var.deployment_slot_enabled
        mutation    = false
      }
    }
    tests = {
      base_url                 = module.honua.function_app_url
      readiness_url            = "${module.honua.function_app_url}/healthz/ready"
      admin_url                = "${module.honua.function_app_url}/api/v1/admin"
      expected_environment     = module.honua.environment
      expected_deployment_mode = "SingleInstance"
    }
    lifecycle = {
      profile            = "ephemeral"
      reuses_shared_data = var.existing_db_fqdn != "" || nonsensitive(var.existing_db_connection_string) != ""
    }
  }

  operations_contract = {
    schema_version = "v1"
    observability = {
      telemetry_policy = module.honua.control_plane_telemetry_policy
    }
    grouping = {
      region         = var.location
      resource_group = module.honua.resource_group_name
      tags           = var.tags
    }
    secret_store = {
      provider = "azure-key-vault"
    }
  }
}

output "honua_url" {
  value = module.honua.function_app_url
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

output "deployment_contract" {
  value = local.deployment_contract
}

output "validation_contract" {
  value = local.validation_contract
}

output "operations_contract" {
  value = local.operations_contract
}
