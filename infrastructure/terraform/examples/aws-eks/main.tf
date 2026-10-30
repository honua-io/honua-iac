provider "aws" {
  region = var.region
}

module "eks" {
  source = "../../modules/aws-eks"

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
  cluster_secret_encryption_enabled        = var.cluster_secret_encryption_enabled
  cluster_secret_encryption_key_arn        = var.cluster_secret_encryption_key_arn

  workload_identity_mode                  = var.workload_identity_mode
  kubernetes_namespace                    = var.kubernetes_namespace
  server_service_account_name             = var.server_service_account_name
  gp_job_namespace                        = var.gp_job_namespace
  gp_job_service_account_name             = var.gp_job_service_account_name
  gp_job_image                            = var.gp_job_image
  gp_job_data_bucket_arn                  = var.gp_job_data_bucket_arn
  gp_job_data_bucket_enabled              = var.gp_job_data_bucket_enabled
  gp_job_reads_server_secrets             = var.gp_job_reads_server_secrets
  permissions_boundary_arn                = var.permissions_boundary_arn
  infrastructure_permissions_boundary_arn = var.infrastructure_permissions_boundary_arn

  admin_password                                    = var.honua_admin_password
  connection_encryption_master_key                  = var.honua_connection_encryption_master_key
  secrets_kms_key_arn                               = var.secrets_kms_key_arn
  audit_chain_key_secret_arn                        = var.audit_chain_key_secret_arn
  audit_chain_key_secret_kms_key_arn                = var.audit_chain_key_secret_kms_key_arn
  operation_key_ring_certificate_secret_arn         = var.operation_key_ring_certificate_secret_arn
  operation_key_ring_certificate_secret_kms_key_arn = var.operation_key_ring_certificate_secret_kms_key_arn

  db_password                     = var.db_password
  existing_db_endpoint            = var.existing_db_endpoint
  existing_db_connection_string   = var.existing_db_connection_string
  db_instance_class               = var.db_instance_class
  db_publicly_accessible          = var.db_publicly_accessible
  db_additional_ingress_cidrs     = var.db_additional_ingress_cidrs
  rds_deletion_protection         = var.rds_deletion_protection
  enable_postgis                  = var.enable_postgis
  postgis_readiness_max_attempts  = var.postgis_readiness_max_attempts
  postgis_readiness_sleep_seconds = var.postgis_readiness_sleep_seconds

  redis_enabled   = var.enable_redis
  redis_node_type = var.redis_node_type

  operations_policy_rules = var.operations_policy_rules
  cors_allowed_origins    = var.cors_allowed_origins

  domain_name                    = var.domain_name
  route53_zone_id                = var.route53_zone_id
  public_base_url                = var.public_base_url
  subject_alternative_names      = var.subject_alternative_names
  ingress_load_balancer_hostname = var.ingress_load_balancer_hostname

  enable_bedrock_ai          = var.enable_bedrock_ai
  bedrock_ai_model           = var.bedrock_ai_model
  bedrock_ai_region          = var.bedrock_ai_region
  bedrock_ai_max_tokens      = var.bedrock_ai_max_tokens
  bedrock_ai_timeout_seconds = var.bedrock_ai_timeout_seconds
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
