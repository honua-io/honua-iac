// Pass through the canonical platform/component outputs.

output "resource_group_name" {
  value = module.platform.resource_group_name
}

output "environment" {
  value = module.platform.environment
}

output "cluster_name" {
  value = module.platform.cluster_name
}

output "cluster_id" {
  value = module.platform.cluster_id
}

output "kube_config_raw" {
  value = module.platform.kube_config_raw
}

output "control_plane_target_kind" {
  value = module.platform.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.platform.control_plane_backend_name
}

output "control_plane_telemetry_policy" {
  value = module.platform.control_plane_telemetry_policy
}

output "honua_metrics_target" {
  value = module.platform.honua_metrics_target
}
