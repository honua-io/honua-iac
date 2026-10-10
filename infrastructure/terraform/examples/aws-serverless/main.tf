provider "aws" {
  region = var.region
}

module "honua" {
  permissions_boundary_arn      = var.permissions_boundary_arn
  use_batch_service_linked_role = var.use_batch_service_linked_role
  source                        = "../../modules/aws-serverless"
  enable_bedrock_ai             = var.enable_bedrock_ai
  bedrock_ai_model              = var.bedrock_ai_model
  bedrock_ai_region             = var.bedrock_ai_region
  bedrock_ai_max_tokens         = var.bedrock_ai_max_tokens
  bedrock_ai_timeout_seconds    = var.bedrock_ai_timeout_seconds

  environment                     = var.environment
  name_prefix                     = var.name_prefix
  existing_vpc_id                 = local.install_net_id
  existing_vpc_cidr               = local.install_net_cidr
  existing_public_subnet_ids      = local.install_net_pub_sub
  existing_private_subnet_ids     = local.install_net_prv_sub
  image                           = local.install_image
  image_repository_policy_mode    = var.image_repository_policy_mode
  lambda_architectures            = var.lambda_architectures
  lambda_alias_name               = var.lambda_alias_name
  lambda_alias_version            = var.lambda_alias_version
  admin_password                  = var.honua_admin_password
  db_password                     = var.db_password
  existing_db_endpoint            = local.install_db_host
  existing_db_connection_string   = var.existing_db_connection_string
  db_publicly_accessible          = local.install_db_public
  db_additional_ingress_cidrs     = var.db_additional_ingress_cidrs
  enable_postgis                  = local.install_db_postgis
  postgis_readiness_max_attempts  = local.install_db_rdy_max
  postgis_readiness_sleep_seconds = local.install_db_rdy_sleep
  redis_enabled                   = var.redis_enabled
  redis_connection_string         = var.redis_connection_string
  redis_connection_cidrs          = var.redis_connection_cidrs
  skip_migrations                 = var.skip_migrations
  tags                            = var.tags

  # Required with Redis: the Lambda receives only an aws:secretsmanager: reference.
  operation_key_ring_certificate_secret_arn         = var.operation_key_ring_certificate_secret_arn
  operation_key_ring_certificate_secret_kms_key_arn = var.operation_key_ring_certificate_secret_kms_key_arn

  # Recommended: audit rows are hash-chained under this key (reference only).
  audit_chain_key_secret_arn         = var.audit_chain_key_secret_arn
  audit_chain_key_secret_kms_key_arn = var.audit_chain_key_secret_kms_key_arn

  enable_dashboard       = var.enable_dashboard
  enable_xray_tracing    = var.enable_xray_tracing
  enable_lambda_insights = var.enable_lambda_insights

  licensing_mode                 = var.licensing_mode
  enable_pro_license             = var.enable_pro_license
  pro_license_content            = var.pro_license_content
  pro_license_key_id             = var.pro_license_key_id
  pro_license_trusted_public_key = var.pro_license_trusted_public_key


  enable_control_plane_events            = var.enable_control_plane_events
  control_plane_events_image             = var.control_plane_events_image
  control_plane_events_memory_size       = var.control_plane_events_memory_size
  control_plane_events_timeout_seconds   = var.control_plane_events_timeout_seconds
  control_plane_scheduled_tick_schedules = var.control_plane_scheduled_tick_schedules

  cors_allowed_origins = var.cors_allowed_origins

  # GP on AWS Batch: the Lambda+Batch cell. use_batch_service_linked_role is
  # wired above with the other certification-cell inputs.
  enable_gp_batch              = var.enable_gp_batch
  gp_batch_image               = var.gp_batch_image
  gp_batch_cpu_architecture    = var.gp_batch_cpu_architecture
  gp_batch_max_vcpus           = var.gp_batch_max_vcpus
  gp_batch_data_bucket_arn     = var.gp_batch_data_bucket_arn
  gp_batch_data_bucket_enabled = var.gp_batch_data_bucket_enabled

  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI       = "true"
  }
}

output "dashboard_name" {
  value = module.honua.dashboard_name
}

output "dashboard_url" {
  value = module.honua.dashboard_url
}

output "honua_url" {
  value = module.honua.api_endpoint
}

output "environment" {
  value = module.honua.environment
}

output "aws_region" {
  value = module.honua.aws_region
}

output "lambda_architectures" {
  description = "Instruction-set architectures of the Honua Lambda function."
  value       = module.honua.lambda_architectures
}

output "lambda_function_name" {
  value = module.honua.lambda_function_name
}

output "lambda_function_arn" {
  value = module.honua.lambda_function_arn
}

output "lambda_function_version" {
  value = module.honua.lambda_function_version
}

output "lambda_alias_name" {
  value = module.honua.lambda_alias_name
}

output "lambda_alias_arn" {
  value = module.honua.lambda_alias_arn
}

output "lambda_alias_invoke_arn" {
  value = module.honua.lambda_alias_invoke_arn
}

output "lambda_alias_function_version" {
  value = module.honua.lambda_alias_function_version
}

output "control_plane_target_kind" {
  value = module.honua.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.honua.control_plane_backend_name
}

output "control_plane_target_id" {
  value = module.honua.control_plane_target_id
}

output "control_plane_target_name" {
  value = module.honua.control_plane_target_name
}

output "control_plane_target_resource_id" {
  value = module.honua.control_plane_target_resource_id
}

output "control_plane_telemetry_policy" {
  value = module.honua.control_plane_telemetry_policy
}

output "control_plane_current_revision" {
  value = module.honua.control_plane_current_revision
}

output "control_plane_desired_revision" {
  value = module.honua.control_plane_desired_revision
}

output "db_endpoint" {
  value     = module.honua.db_endpoint
  sensitive = true
}

output "admin_password_secret_arn" {
  description = "Secrets Manager ARN for the admin password."
  value       = module.honua.admin_password_secret_arn
}

output "redis_connection_string" {
  value     = module.honua.redis_connection_string
  sensitive = true
}

output "licensing_mode" {
  value = module.honua.licensing_mode
}

output "pro_license_enabled" {
  value = module.honua.pro_license_enabled
}

output "pro_license_secret_arn" {
  value = module.honua.pro_license_secret_arn
}

output "control_plane_events_enabled" {
  value = module.honua.control_plane_events_enabled
}

output "control_plane_reconcile_function_name" {
  value = module.honua.control_plane_reconcile_function_name
}

output "control_plane_reconcile_function_arn" {
  value = module.honua.control_plane_reconcile_function_arn
}

output "control_plane_backstop_function_name" {
  value = module.honua.control_plane_backstop_function_name
}

output "control_plane_backstop_function_arn" {
  value = module.honua.control_plane_backstop_function_arn
}

output "control_plane_batch_event_rule_arn" {
  value = module.honua.control_plane_batch_event_rule_arn
}

# --- GP on AWS Batch --------------------------------------------------------
# All null when enable_gp_batch is false.

check "gp_batch_image_is_generic" {
  assert {
    condition     = !var.enable_gp_batch || var.gp_batch_image != ""
    error_message = "enable_gp_batch is true but gp_batch_image is empty, so the Batch job definitions fall back to honua_image_uri (the Lambda image). The job definitions run the image's own entrypoint; pass the digest-pinned generic (ECS) server image as gp_batch_image."
  }
}

output "gp_batch_enabled" {
  description = "Whether the GP-on-Batch backend was provisioned."
  value       = module.honua.gp_batch_enabled
}

output "gp_batch_image" {
  description = "Effective image the GP job definitions run."
  value       = module.honua.gp_batch_image
}

output "gp_batch_cpu_architecture" {
  description = "Fargate CPU architecture of the GP job definitions."
  value       = module.honua.gp_batch_cpu_architecture
}

output "gp_job_queue_name" {
  description = "Name of the GP Fargate Spot Batch job queue."
  value       = module.honua.gp_job_queue_name
}

output "gp_job_queue_arn" {
  description = "ARN of the GP Fargate Spot Batch job queue."
  value       = module.honua.gp_job_queue_arn
}

output "gp_job_definition_names" {
  description = "Map of GP job-definition size tier => name ({ s, m, l, xl })."
  value       = module.honua.gp_job_definition_names
}

output "gp_job_definition_arns" {
  description = "Map of GP job-definition size tier => ARN ({ s, m, l, xl })."
  value       = module.honua.gp_job_definition_arns
}

output "gp_compute_environment_name" {
  description = "Name of the GP Fargate Spot Batch compute environment."
  value       = module.honua.gp_compute_environment_name
}

output "gp_compute_environment_arn" {
  description = "ARN of the GP Fargate Spot Batch compute environment."
  value       = module.honua.gp_compute_environment_arn
}

# --- Out-of-band migration inputs ---------------------------------------------
# With skip_migrations = true (the default) the Lambda never migrates the
# database. Until honua-server ships a HONUA_MIGRATE_ONLY exit mode (2026.1.x),
# a release harness or operator runs the generic (ECS) server image once with
# these inputs, waits for /healthz/ready, then stops it, before serving
# traffic. Every value is an ARN or ID; no secret value is output here.

output "migrate_required" {
  description = "True when the Lambda skips migrations, so the database must be migrated out-of-band before serving."
  value       = var.skip_migrations
}

output "migrate_db_connection_secret_arn" {
  description = "Secrets Manager ARN of the database connection string; set it as ConnectionStrings__DefaultConnection (aws:secretsmanager:<arn>) or resolve it into the migration container."
  value       = module.honua.db_connection_secret_arn
}

output "migrate_admin_password_secret_arn" {
  description = "Secrets Manager ARN of the admin password the server expects as HONUA_ADMIN_PASSWORD."
  value       = module.honua.admin_password_secret_arn
}

output "migrate_master_key_secret_arn" {
  description = "Secrets Manager ARN of the connection-encryption master key the server expects as Security__ConnectionEncryption__MasterKey."
  value       = module.honua.master_key_secret_arn
}

output "migrate_vpc_id" {
  description = "VPC of the cell, for running the migration as an in-VPC task."
  value       = module.honua.vpc_id
}

output "migrate_private_subnet_ids" {
  description = "Private subnets for an in-VPC migration task (the database is reachable from them)."
  value       = module.honua.private_subnet_ids
}

output "migrate_security_group_id" {
  description = "Security group the database admits (the Lambda's); attach it to an in-VPC migration task."
  value       = module.honua.lambda_security_group_id
}

output "migrate_guidance" {
  description = "How to migrate this cell out-of-band."
  value       = var.skip_migrations ? "Run the digest-pinned generic (ECS) honua-server image once with ConnectionStrings__DefaultConnection, HONUA_ADMIN_PASSWORD and Security__ConnectionEncryption__MasterKey resolved from the migrate_*_secret_arn outputs, either as an in-VPC task (migrate_private_subnet_ids + migrate_security_group_id) or from a runner admitted by db_publicly_accessible + db_additional_ingress_cidrs. Wait for GET /healthz/ready = 200, then stop it before serving. Replace with HONUA_MIGRATE_ONLY once honua-server ships it (2026.1.x)." : "skip_migrations is false: the Lambda migrates on startup; no out-of-band step is required."
}
