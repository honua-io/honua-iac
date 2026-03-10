provider "aws" {
  region = var.region
}

module "eks" {
  source = "../../modules/aws-eks"

  name_prefix          = var.name_prefix
  environment          = var.environment
  tags                 = var.tags
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  cluster_version      = var.cluster_version
  node_instance_types  = var.node_instance_types
  node_cpu_architecture = var.node_cpu_architecture
  node_min_size        = var.node_min_size
  node_max_size        = var.node_max_size
  node_desired_size    = var.node_desired_size
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "environment" {
  value = module.eks.environment
}

output "cluster_arn" {
  value = module.eks.cluster_arn
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "vpc_id" {
  value = module.eks.vpc_id
}

output "control_plane_target_kind" {
  value = module.eks.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.eks.control_plane_backend_name
}

output "control_plane_telemetry_policy" {
  value = module.eks.control_plane_telemetry_policy
}

output "honua_metrics_target" {
  value = module.eks.honua_metrics_target
}
