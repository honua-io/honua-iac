// Pass through the canonical platform/component outputs.

output "environment" {
  value = module.platform.environment
}

output "function_app_name" {
  value = module.platform.function_app_name
}

output "function_app_id" {
  value = module.platform.function_app_id
}

output "resource_group_name" {
  value = module.platform.resource_group_name
}

output "function_app_slot_name" {
  value = module.platform.function_app_slot_name
}

output "function_app_slot_id" {
  value = module.platform.function_app_slot_id
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

output "control_plane_current_revision" {
  value = module.platform.control_plane_current_revision
}

output "control_plane_desired_revision" {
  value = module.platform.control_plane_desired_revision
}

output "control_plane_slot_name" {
  value = module.platform.control_plane_slot_name
}

output "control_plane_current_image" {
  value = module.platform.control_plane_current_image
}

output "control_plane_desired_image" {
  value = module.platform.control_plane_desired_image
}

output "function_app_url" {
  value = module.platform.function_app_url
}

output "db_fqdn" {
  value = module.platform.db_fqdn
}

output "db_connection_string" {
  value = module.platform.db_connection_string
}

output "redis_connection_string" {
  value = module.platform.redis_connection_string
}

output "redis_connection_secret_id" {
  value = module.platform.redis_connection_secret_id
}
