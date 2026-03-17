// Compatibility wrapper around the canonical implementation.

module "platform" {
  source = "../../platforms/aws-eks"

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
  cluster_addon_versions                   = var.cluster_addon_versions
}
