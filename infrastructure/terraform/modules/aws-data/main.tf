// Compatibility wrapper around the canonical implementation.

module "platform" {
  source = "../../components/data/aws-postgres-redis"

  name_prefix                     = var.name_prefix
  environment                     = var.environment
  tags                            = var.tags
  vpc_cidr                        = var.vpc_cidr
  public_subnet_cidrs             = var.public_subnet_cidrs
  private_subnet_cidrs            = var.private_subnet_cidrs
  enable_nat_gateway              = var.enable_nat_gateway
  single_nat_gateway              = var.single_nat_gateway
  db_username                     = var.db_username
  db_password                     = var.db_password
  db_name                         = var.db_name
  db_instance_class               = var.db_instance_class
  db_allocated_storage            = var.db_allocated_storage
  db_max_allocated_storage        = var.db_max_allocated_storage
  db_engine_version               = var.db_engine_version
  db_publicly_accessible          = var.db_publicly_accessible
  db_additional_ingress_cidrs     = var.db_additional_ingress_cidrs
  db_multi_az                     = var.db_multi_az
  db_require_ssl                  = var.db_require_ssl
  enable_postgis                  = var.enable_postgis
  postgis_readiness_max_attempts  = var.postgis_readiness_max_attempts
  postgis_readiness_sleep_seconds = var.postgis_readiness_sleep_seconds
  redis_enabled                   = var.redis_enabled
  redis_auth_token                = var.redis_auth_token
  redis_node_type                 = var.redis_node_type
  redis_engine_version            = var.redis_engine_version
  redis_parameter_group_name      = var.redis_parameter_group_name
  redis_num_cache_clusters        = var.redis_num_cache_clusters
  redis_port                      = var.redis_port
}
