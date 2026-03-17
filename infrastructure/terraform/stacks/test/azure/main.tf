// Validation stack wrapper around the canonical customer stack.

module "stack" {
  source = "../../customer/azure"

  location                        = var.location
  environment                     = var.environment
  name_prefix                     = var.name_prefix
  honua_admin_password            = var.honua_admin_password
  db_admin_password               = var.db_admin_password
  existing_db_fqdn                = var.existing_db_fqdn
  existing_db_connection_string   = var.existing_db_connection_string
  honua_image                     = var.honua_image
  registry_server                 = var.registry_server
  registry_username               = var.registry_username
  registry_password               = var.registry_password
  enable_postgis                  = var.enable_postgis
  redis_enabled                   = var.redis_enabled
  redis_connection_string         = var.redis_connection_string
  redis_sku_name                  = var.redis_sku_name
  redis_family                    = var.redis_family
  redis_capacity                  = var.redis_capacity
  db_geo_redundant_backup_enabled = var.db_geo_redundant_backup_enabled
  db_backup_retention_days        = var.db_backup_retention_days
  min_replicas                    = var.min_replicas
  max_replicas                    = var.max_replicas
  key_vault_default_action        = var.key_vault_default_action
  db_firewall_start_ip            = var.db_firewall_start_ip
  db_firewall_end_ip              = var.db_firewall_end_ip
  tags                            = var.tags
}

output "honua_url" {
  value = module.stack.honua_url
}

output "environment" {
  value = module.stack.environment
}

output "container_app_name" {
  value = module.stack.container_app_name
}

output "container_app_id" {
  value = module.stack.container_app_id
}

output "container_app_environment_id" {
  value = module.stack.container_app_environment_id
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

output "database_fqdn" {
  value = module.stack.database_fqdn
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
