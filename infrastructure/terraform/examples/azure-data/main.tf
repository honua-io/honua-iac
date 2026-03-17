// Compatibility example wrapper around the canonical customer stack.

module "stack" {
  source = "../../stacks/customer/azure-data"

  location                            = var.location
  environment                         = var.environment
  name_prefix                         = var.name_prefix
  honua_admin_password                = var.honua_admin_password
  db_admin_password                   = var.db_admin_password
  db_sku_name                         = var.db_sku_name
  db_storage_mb                       = var.db_storage_mb
  db_geo_redundant_backup_enabled     = var.db_geo_redundant_backup_enabled
  db_backup_retention_days            = var.db_backup_retention_days
  db_public_network_access            = var.db_public_network_access
  enable_postgis                      = var.enable_postgis
  redis_enabled                       = var.redis_enabled
  redis_sku_name                      = var.redis_sku_name
  redis_family                        = var.redis_family
  redis_capacity                      = var.redis_capacity
  redis_public_network_access_enabled = var.redis_public_network_access_enabled
  key_vault_default_action            = var.key_vault_default_action
  db_firewall_start_ip                = var.db_firewall_start_ip
  db_firewall_end_ip                  = var.db_firewall_end_ip
  tags                                = var.tags
}

output "db_fqdn" {
  value = module.stack.db_fqdn
}

output "db_connection_string" {
  value = module.stack.db_connection_string
}

output "redis_connection_string" {
  value = module.stack.redis_connection_string
}

output "key_vault_id" {
  value = module.stack.key_vault_id
}

output "key_vault_name" {
  value = module.stack.key_vault_name
}

output "resource_group_name" {
  value = module.stack.resource_group_name
}

output "infrastructure_outputs" {
  value = module.stack.infrastructure_outputs
}

output "infrastructure_secrets" {
  value = module.stack.infrastructure_secrets
}
