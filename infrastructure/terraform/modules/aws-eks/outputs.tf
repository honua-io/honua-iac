// Pass through the canonical platform/component outputs.

output "cluster_name" {
  value = module.platform.cluster_name
}

output "environment" {
  value = module.platform.environment
}

output "cluster_arn" {
  value = module.platform.cluster_arn
}

output "cluster_endpoint" {
  value = module.platform.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.platform.cluster_certificate_authority_data
}

output "vpc_id" {
  value = module.platform.vpc_id
}

output "oidc_provider_arn" {
  value = module.platform.oidc_provider_arn
}

output "oidc_provider" {
  value = module.platform.oidc_provider
}

output "cluster_security_group_id" {
  value = module.platform.cluster_security_group_id
}

output "node_security_group_id" {
  value = module.platform.node_security_group_id
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
