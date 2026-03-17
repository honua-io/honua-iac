provider "azurerm" {
  features {}
}

# Provision data tier (PostgreSQL + Redis + Key Vault) independently.
module "data" {
  source = "../../modules/azure-data"

  environment                         = var.environment
  name_prefix                         = var.name_prefix
  location                            = var.location
  admin_password                      = var.honua_admin_password
  db_admin_password                   = var.db_admin_password
  db_sku_name                         = var.db_sku_name
  db_storage_mb                       = var.db_storage_mb
  db_geo_redundant_backup_enabled     = var.db_geo_redundant_backup_enabled
  db_backup_retention_days            = var.db_backup_retention_days
  db_public_network_access            = var.db_public_network_access
  db_firewall_start_ip                = var.db_firewall_start_ip
  db_firewall_end_ip                  = var.db_firewall_end_ip
  enable_postgis                      = var.enable_postgis
  redis_enabled                       = var.redis_enabled
  redis_sku_name                      = var.redis_sku_name
  redis_family                        = var.redis_family
  redis_capacity                      = var.redis_capacity
  redis_public_network_access_enabled = var.redis_public_network_access_enabled
  key_vault_default_action            = var.key_vault_default_action
  tags                                = var.tags
}

locals {
  deployment_contract = {
    schema_version = "v1"
    stack = {
      id          = "azure-data"
      platform    = "azure-data"
      runtime     = "data"
      environment = var.environment
      region      = var.location
    }
    endpoints = {
      public_base_url = null
      readiness_url   = null
      admin_url       = null
      protocol_url    = null
    }
    workload = {
      kind        = "AzureDataServices"
      name        = var.name_prefix
      resource_id = module.data.resource_group_name
    }
    rollout = {
      backend_name       = null
      target_id          = null
      target_name        = null
      target_resource_id = null
      current_revision   = null
      desired_revision   = null
    }
    dependencies = {
      database = {
        kind       = "azure-postgres"
        host       = module.data.db_fqdn
        secret_ref = module.data.db_connection_secret_id
      }
      cache = {
        kind       = "azure-redis"
        enabled    = var.redis_enabled
        host       = null
        secret_ref = module.data.redis_connection_secret_id
      }
      secret_store = {
        kind = "azure-key-vault"
        id   = module.data.key_vault_id
      }
    }
  }

  validation_contract = {
    schema_version = "v1"
    platform = {
      name = "azure-data"
      capabilities = {
        deploy_plan     = false
        mutation        = false
        scale_check     = false
        backup_drill    = true
        idempotency     = true
        protocol_checks = false
      }
    }
    tests = {
      base_url      = null
      readiness_url = null
      admin_url     = null
      protocol_url  = null
    }
    artifacts = {
      terraform_root = path.cwd
      resource_group = module.data.resource_group_name
      region         = var.location
    }
    lifecycle = {
      reuse_data_stack = true
      destroy_mode     = "explicit"
    }
  }

  operations_contract = {
    schema_version = "v1"
    observability = {
      telemetry_policy      = null
      prometheus_job        = null
      prometheus_canary_job = null
      grafana_url           = null
    }
    secrets = {
      secret_store = {
        kind = "azure-key-vault"
        id   = module.data.key_vault_id
      }
      admin_password_secret   = module.data.admin_password_secret_id
      db_connection_secret    = module.data.db_connection_secret_id
      redis_connection_secret = module.data.redis_connection_secret_id
    }
    grouping = {
      environment    = var.environment
      name_prefix    = var.name_prefix
      resource_group = module.data.resource_group_name
      tags           = var.tags
    }
  }
}

output "deployment_contract" {
  description = "Stable deployment contract for validation and operator automation."
  value       = local.deployment_contract
}

output "validation_contract" {
  description = "Stable validation contract for scenario orchestration."
  value       = local.validation_contract
}

output "operations_contract" {
  description = "Stable operations contract for day-2 metadata and secret references."
  value       = local.operations_contract
}

output "db_fqdn" {
  value = module.data.db_fqdn
}

output "db_connection_string" {
  value     = module.data.db_connection_string
  sensitive = true
}

output "redis_connection_string" {
  value     = module.data.redis_connection_string
  sensitive = true
}

output "key_vault_id" {
  value = module.data.key_vault_id
}

output "key_vault_name" {
  value = module.data.key_vault_name
}

output "resource_group_name" {
  value = module.data.resource_group_name
}
