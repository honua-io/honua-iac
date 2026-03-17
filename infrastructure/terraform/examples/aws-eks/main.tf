// Compatibility example wrapper around the canonical customer stack.

module "stack" {
  source = "../../stacks/customer/aws-eks"

  region                                   = var.region
  name_prefix                              = var.name_prefix
  environment                              = var.environment
  tags                                     = var.tags
  vpc_cidr                                 = var.vpc_cidr
  public_subnet_cidrs                      = var.public_subnet_cidrs
  private_subnet_cidrs                     = var.private_subnet_cidrs
  cluster_version                          = var.cluster_version
  node_instance_types                      = var.node_instance_types
  node_cpu_architecture                    = var.node_cpu_architecture
  node_min_size                            = var.node_min_size
  node_max_size                            = var.node_max_size
  node_desired_size                        = var.node_desired_size
  cluster_endpoint_public_access           = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions
}

output "cluster_name" {
  value = module.stack.cluster_name
}

output "environment" {
  value = module.stack.environment
}

output "cluster_arn" {
  value = module.stack.cluster_arn
}

output "cluster_endpoint" {
  value = module.stack.cluster_endpoint
}

output "vpc_id" {
  value = module.stack.vpc_id
}

output "control_plane_target_kind" {
  value = module.stack.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.stack.control_plane_backend_name
}

output "control_plane_telemetry_policy" {
  value = module.stack.control_plane_telemetry_policy
}

output "honua_metrics_target" {
  value = module.stack.honua_metrics_target
}

output "infrastructure_outputs" {
  value = module.stack.infrastructure_outputs
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
