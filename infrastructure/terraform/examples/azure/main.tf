provider "azurerm" {
  features {}
}

module "honua" {
  source = "../../modules/azure-aca"

  environment                               = var.environment
  name_prefix                               = var.name_prefix
  location                                  = var.location
  image                                     = local.install_image
  admin_password                            = var.honua_admin_password
  connection_encryption_master_key          = var.honua_connection_encryption_master_key
  db_admin_password                         = var.db_admin_password
  existing_db_fqdn                          = local.install_db_host
  existing_db_connection_string             = var.existing_db_connection_string
  db_firewall_start_ip                      = local.install_net_fw_start
  db_firewall_end_ip                        = local.install_net_fw_end
  db_geo_redundant_backup_enabled           = var.db_geo_redundant_backup_enabled
  db_backup_retention_days                  = var.db_backup_retention_days
  enable_postgis                            = local.install_db_postgis
  redis_enabled                             = var.redis_enabled
  redis_connection_string                   = var.redis_connection_string
  redis_sku_name                            = var.redis_sku_name
  redis_family                              = var.redis_family
  redis_capacity                            = var.redis_capacity
  min_replicas                              = var.min_replicas
  max_replicas                              = var.max_replicas
  deployment_mode                           = var.deployment_mode
  file_storage_provider                     = var.file_storage_provider
  file_storage_azure_blob_connection_string = var.file_storage_azure_blob_connection_string
  file_storage_azure_blob_container_name    = var.file_storage_azure_blob_container_name
  file_storage_azure_blob_prefix            = var.file_storage_azure_blob_prefix
  key_vault_default_action                  = var.key_vault_default_action
  registry_server                           = local.install_reg_server
  registry_username                         = var.registry_username
  registry_password                         = var.registry_password
  tags                                      = var.tags

  additional_env = {
    HONUA_SERVE_ADMIN_UI            = "true"
    HONUA_ADMIN_UI                  = "true"
    HostValidation__AllowedHosts__0 = "*.azurecontainerapps.io"
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
