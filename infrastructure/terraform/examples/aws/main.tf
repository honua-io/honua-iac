provider "aws" {
  region = var.region
}

module "honua" {
  source = "../../modules/aws-ecs"

  environment                      = var.environment
  name_prefix                      = var.name_prefix
  existing_vpc_id                  = local.install_net_id
  existing_vpc_cidr                = local.install_net_cidr
  existing_public_subnet_ids       = local.install_net_pub_sub
  existing_private_subnet_ids      = local.install_net_prv_sub
  image                            = local.install_image
  ai_provider_secret_arn           = var.ai_provider_secret_arn
  ai_provider_secret_kms_key_arn   = var.ai_provider_secret_kms_key_arn
  task_cpu_architecture            = var.task_cpu_architecture
  admin_password                   = var.honua_admin_password
  connection_encryption_master_key = var.honua_connection_encryption_master_key
  db_password                      = var.db_password
  existing_db_endpoint             = local.install_db_host
  existing_db_connection_string    = var.existing_db_connection_string
  db_publicly_accessible           = local.install_db_public
  db_additional_ingress_cidrs      = var.db_additional_ingress_cidrs
  enable_postgis                   = local.install_db_postgis
  postgis_readiness_max_attempts   = local.install_db_rdy_max
  postgis_readiness_sleep_seconds  = local.install_db_rdy_sleep
  redis_enabled                    = var.redis_enabled
  redis_connection_string          = var.redis_connection_string
  redis_connection_cidrs           = var.redis_connection_cidrs
  desired_count                    = var.desired_count
  max_capacity                     = var.max_capacity
  deployment_mode                  = var.deployment_mode
  file_storage_provider            = var.file_storage_provider
  file_storage_aws_s3_bucket_name  = var.file_storage_aws_s3_bucket_name
  file_storage_aws_s3_region       = var.file_storage_aws_s3_region
  file_storage_aws_s3_key_prefix   = var.file_storage_aws_s3_key_prefix
  canary_enabled                   = var.canary_enabled
  canary_image                     = var.canary_image
  canary_desired_count             = var.canary_desired_count
  canary_weight_percentage         = var.canary_weight_percentage
  alb_deletion_protection          = var.alb_deletion_protection
  alb_access_logs_enabled          = var.alb_access_logs_enabled
  alb_access_logs_force_destroy    = var.alb_access_logs_force_destroy
  alb_certificate_arn              = var.alb_certificate_arn
  domain_name                      = var.domain_name
  route53_zone_id                  = var.route53_zone_id
  domain_alias_record_enabled      = var.domain_alias_record_enabled
  subject_alternative_names        = var.subject_alternative_names
  allow_https_ingress_cidrs        = local.install_net_https
  allow_http_ingress_cidrs         = local.install_net_http
  waf_web_acl_arn                  = var.waf_web_acl_arn
  tags                             = var.tags

  additional_env = {
    HONUA_SERVE_ADMIN_UI    = "true"
    HONUA_ADMIN_UI          = "true"
    HostValidation__Enabled = "false"
  }
}
