// Pass through the canonical platform/component outputs.

output "environment" {
  value = module.platform.environment
}

output "container_app_name" {
  value = module.platform.container_app_name
}

output "container_app_id" {
  value = module.platform.container_app_id
}

output "container_app_environment_id" {
  value = module.platform.container_app_environment_id
}

output "resource_group_name" {
  value = module.platform.resource_group_name
}

output "control_plane_target_kind" {
  value = module.platform.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.platform.control_plane_backend_name
}

output "control_plane_target_id" {
  value = module.platform.control_plane_target_id
}

output "control_plane_target_name" {
  value = module.platform.control_plane_target_name
}

output "control_plane_target_resource_id" {
  value = module.platform.control_plane_target_resource_id
}

output "control_plane_target_resource_group" {
  value = module.platform.control_plane_target_resource_group
}

output "control_plane_telemetry_policy" {
  value = module.platform.control_plane_telemetry_policy
}

output "container_app_fqdn" {
  value = module.platform.container_app_fqdn
}

output "database_fqdn" {
  value = module.platform.database_fqdn
}

output "key_vault_id" {
  value = module.platform.key_vault_id
}

output "db_connection_secret_id" {
  value = module.platform.db_connection_secret_id
}

output "admin_password_secret_id" {
  value = module.platform.admin_password_secret_id
}

output "redis_connection_secret_id" {
  value = module.platform.redis_connection_secret_id
}
