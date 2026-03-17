// Compatibility wrapper around the canonical implementation.

module "platform" {
  source = "../../components/data/azure-postgres-redis"

  name_prefix                             = var.name_prefix
  environment                             = var.environment
  location                                = var.location
  tags                                    = var.tags
  db_admin_username                       = var.db_admin_username
  db_admin_password                       = var.db_admin_password
  db_name                                 = var.db_name
  db_sku_name                             = var.db_sku_name
  db_storage_mb                           = var.db_storage_mb
  db_version                              = var.db_version
  db_public_network_access                = var.db_public_network_access
  db_firewall_start_ip                    = var.db_firewall_start_ip
  db_firewall_end_ip                      = var.db_firewall_end_ip
  db_geo_redundant_backup_enabled         = var.db_geo_redundant_backup_enabled
  db_backup_retention_days                = var.db_backup_retention_days
  enable_postgis                          = var.enable_postgis
  redis_enabled                           = var.redis_enabled
  redis_sku_name                          = var.redis_sku_name
  redis_family                            = var.redis_family
  redis_capacity                          = var.redis_capacity
  redis_enable_non_ssl_port               = var.redis_enable_non_ssl_port
  redis_public_network_access_enabled     = var.redis_public_network_access_enabled
  redis_subnet_id                         = var.redis_subnet_id
  admin_password                          = var.admin_password
  key_vault_purge_protection_enabled      = var.key_vault_purge_protection_enabled
  key_vault_soft_delete_retention_days    = var.key_vault_soft_delete_retention_days
  key_vault_public_network_access_enabled = var.key_vault_public_network_access_enabled
  key_vault_default_action                = var.key_vault_default_action
  key_vault_bypass                        = var.key_vault_bypass
  key_vault_ip_rules                      = var.key_vault_ip_rules
  secret_expiration_days                  = var.secret_expiration_days
}
