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
  redis_enabled                   = var.redis_enabled
  redis_connection_string         = var.redis_connection_string
  redis_sku_name                  = var.redis_sku_name
  redis_family                    = var.redis_family
  redis_capacity                  = var.redis_capacity
  min_replicas                    = var.min_replicas
  max_replicas                    = var.max_replicas
  key_vault_default_action        = var.key_vault_default_action
  registry_server                 = var.registry_server
  registry_username               = var.registry_username
  registry_password               = var.registry_password
  tags                            = var.tags

  additional_env = {
    HONUA_SERVE_ADMIN_UI            = "true"
    HONUA_ADMIN_UI                  = "true"
    HostValidation__AllowedHosts__0 = "*.azurecontainerapps.io"
  }
}

locals {
  deployment_contract = {
    schema_version = "v1"
    stack = {
      id          = "azure-aca"
      platform    = "azure-container-apps"
      runtime     = "containers"
      environment = module.honua.environment
      region      = var.location
    }
    endpoints = {
      public_base_url = module.honua.container_app_fqdn
      readiness_path  = "/healthz/ready"
      liveness_path   = "/healthz/live"
      admin_base_path = "/api/v1/admin"
      openapi_path    = "/openapi.json"
    }
    workload = {
      kind           = module.honua.control_plane_target_kind
      name           = module.honua.container_app_name
      resource_id    = module.honua.container_app_id
      resource_group = module.honua.resource_group_name
      environment_id = module.honua.container_app_environment_id
    }
    rollout = {
      backend_name          = module.honua.control_plane_backend_name
      target_id             = module.honua.control_plane_target_id
      target_name           = module.honua.control_plane_target_name
      target_resource_id    = module.honua.control_plane_target_resource_id
      target_resource_group = module.honua.control_plane_target_resource_group
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
      name = "azure-container-apps"
      capabilities = {
        deploy_plan = false
        mutation    = false
      }
    }
    tests = {
      base_url      = module.honua.container_app_fqdn
      readiness_url = "${module.honua.container_app_fqdn}/healthz/ready"
      admin_url     = "${module.honua.container_app_fqdn}/api/v1/admin"
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

  infrastructure_outputs = {
    environment = module.honua.environment
    location    = var.location
    endpoints = {
      public_base_url = module.honua.container_app_fqdn
    }
    workload = {
      container_app_name           = module.honua.container_app_name
      container_app_id             = module.honua.container_app_id
      container_app_environment_id = module.honua.container_app_environment_id
      resource_group_name          = module.honua.resource_group_name
    }
  }

  infrastructure_secrets = {
    database_fqdn = module.honua.database_fqdn
  }

  honua_integration_outputs = {
    control_plane = {
      target_kind           = module.honua.control_plane_target_kind
      backend_name          = module.honua.control_plane_backend_name
      target_id             = module.honua.control_plane_target_id
      target_name           = module.honua.control_plane_target_name
      target_resource_id    = module.honua.control_plane_target_resource_id
      target_resource_group = module.honua.control_plane_target_resource_group
      telemetry_policy      = module.honua.control_plane_telemetry_policy
    }
    contracts = {
      deployment = local.deployment_contract
      validation = local.validation_contract
      operations = local.operations_contract
    }
  }
}

output "honua_url" {
  value = module.honua.container_app_fqdn
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

output "infrastructure_outputs" {
  value = local.infrastructure_outputs
}

output "infrastructure_secrets" {
  value     = local.infrastructure_secrets
  sensitive = true
}

output "honua_integration_outputs" {
  value = local.honua_integration_outputs
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
