# Legacy scalar outputs for this root.
#
# NON-AUTHORITATIVE. These are kept for backward compatibility with operator
# scripts and older validation plumbing only. They carry no schema version, no
# immutable identity, and no contract digest, so they cannot prove that IaC,
# Helm, DevOps, server, and the release candidate refer to the same deployment.
#
# The authoritative surface is the honua.operator-contract/v1 triple in
# operator-contract.tf: deployment_contract, validation_contract, and
# operations_contract. New certified automation must consume those and must not
# reconstruct a handoff from the scalars below. See docs/operator-contract.md
# for the deprecation policy.
#
# The marketplace `install_contract` / `deploy_contract` outputs in
# marketplace.tf are a separate, still-current surface; they are not part of
# this deprecation.

output "honua_url" {
  description = "Non-authoritative legacy scalar. Use deployment_contract.endpoints.public_base_url."
  value       = module.honua.service_url
}

output "service_domain_record_fqdn" {
  description = "Non-authoritative legacy scalar. Use deployment_contract.endpoints.custom_domain."
  value       = module.honua.service_domain_record_fqdn
}

output "ecs_cluster_name" {
  description = "Non-authoritative legacy scalar. Use deployment_contract.workload.cluster_name."
  value       = module.honua.ecs_cluster_name
}

output "ecs_service_name" {
  description = "Non-authoritative legacy scalar. Use deployment_contract.workload.name."
  value       = module.honua.ecs_service_name
}

output "canary_enabled" {
  description = "Non-authoritative legacy scalar. Use deployment_contract.rollout.canary.enabled."
  value       = module.honua.canary_enabled
}

output "canary_ecs_service_name" {
  description = "Non-authoritative legacy scalar. Use deployment_contract.rollout.canary.service_name."
  value       = module.honua.canary_ecs_service_name
}

output "canary_verification_header_name" {
  description = "Non-authoritative legacy scalar. Use deployment_contract.rollout.canary.verification_header_name."
  value       = module.honua.canary_verification_header_name
}

output "canary_verification_header_value" {
  description = "Non-authoritative legacy scalar. Deliberately absent from the operator contract: it is a routing credential, not a reference."
  value       = module.honua.canary_verification_header_value
}

output "control_plane_target_kind" {
  description = "Non-authoritative legacy scalar. Use deployment_contract.rollout.target_kind."
  value       = module.honua.control_plane_target_kind
}

output "control_plane_backend_name" {
  description = "Non-authoritative legacy scalar. Use deployment_contract.rollout.backend_name."
  value       = module.honua.control_plane_backend_name
}

output "control_plane_telemetry_policy" {
  description = "Non-authoritative legacy scalar. Use operations_contract.observability.telemetry_policy."
  value       = module.honua.control_plane_telemetry_policy
}

output "control_plane_telemetry_prometheus_job" {
  description = "Non-authoritative legacy scalar. Use operations_contract.observability.prometheus_job."
  value       = module.honua.control_plane_telemetry_prometheus_job
}

output "control_plane_telemetry_prometheus_canary_job" {
  description = "Non-authoritative legacy scalar. Use operations_contract.observability.prometheus_canary_job."
  value       = module.honua.control_plane_telemetry_prometheus_canary_job
}

output "db_endpoint" {
  description = "Non-authoritative legacy scalar. Use deployment_contract.dependencies.database.endpoint."
  value       = module.honua.db_endpoint
  sensitive   = true
}

output "redis_primary_endpoint" {
  description = "Non-authoritative legacy scalar. The operator contract exposes the Redis secret reference instead of the endpoint."
  value       = module.honua.redis_primary_endpoint
  sensitive   = true
}
