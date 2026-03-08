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
