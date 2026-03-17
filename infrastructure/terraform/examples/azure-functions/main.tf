// Compatibility example wrapper around the canonical customer stack.

module "stack" {
  source = "../../stacks/customer/azure-functions"

  location                                = var.location
  environment                             = var.environment
  name_prefix                             = var.name_prefix
  honua_admin_password                    = var.honua_admin_password
  db_admin_password                       = var.db_admin_password
  existing_db_fqdn                        = var.existing_db_fqdn
  existing_db_connection_string           = var.existing_db_connection_string
  honua_image                             = var.honua_image
  registry_server                         = var.registry_server
  registry_username                       = var.registry_username
  registry_password                       = var.registry_password
  deployment_slot_enabled                 = var.deployment_slot_enabled
  deployment_slot_name                    = var.deployment_slot_name
  deployment_slot_image                   = var.deployment_slot_image
  plan_sku_name                           = var.plan_sku_name
  enable_postgis                          = var.enable_postgis
  redis_enabled                           = var.redis_enabled
  redis_connection_string                 = var.redis_connection_string
  redis_sku_name                          = var.redis_sku_name
  redis_family                            = var.redis_family
  redis_capacity                          = var.redis_capacity
  key_vault_public_network_access_enabled = var.key_vault_public_network_access_enabled
  storage_network_default_action          = var.storage_network_default_action
  db_geo_redundant_backup_enabled         = var.db_geo_redundant_backup_enabled
  db_backup_retention_days                = var.db_backup_retention_days
  db_firewall_start_ip                    = var.db_firewall_start_ip
  db_firewall_end_ip                      = var.db_firewall_end_ip
  skip_migrations                         = var.skip_migrations
  tags                                    = var.tags
}

output "honua_url" {
  value = module.stack.honua_url
}

output "environment" {
  value = module.stack.environment
}

output "function_app_name" {
  value = module.stack.function_app_name
}

output "function_app_id" {
  value = module.stack.function_app_id
}

output "control_plane_target_kind" {
  value = module.stack.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.stack.control_plane_backend_name
}

output "control_plane_target_id" {
  value = module.stack.control_plane_target_id
}

output "control_plane_target_name" {
  value = module.stack.control_plane_target_name
}

output "control_plane_target_resource_id" {
  value = module.stack.control_plane_target_resource_id
}

output "control_plane_target_resource_group" {
  value = module.stack.control_plane_target_resource_group
}

output "control_plane_telemetry_policy" {
  value = module.stack.control_plane_telemetry_policy
}

output "control_plane_current_revision" {
  value = module.stack.control_plane_current_revision
}

output "control_plane_desired_revision" {
  value = module.stack.control_plane_desired_revision
}

output "control_plane_slot_name" {
  value = module.stack.control_plane_slot_name
}

output "control_plane_current_image" {
  value = module.stack.control_plane_current_image
}

output "control_plane_desired_image" {
  value = module.stack.control_plane_desired_image
}

output "function_app_slot_name" {
  value = module.stack.function_app_slot_name
}

output "function_app_slot_id" {
  value = module.stack.function_app_slot_id
}

output "db_fqdn" {
  value = module.stack.db_fqdn
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

output "honua_integration_outputs" {
  value = module.stack.honua_integration_outputs
}

output "deployment_contract" {
  value = module.stack.deployment_contract
}

output "validation_contract" {
  value = module.stack.validation_contract
}

output "operations_contract" {
  value = module.stack.operations_contract
}
