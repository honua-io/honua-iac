provider "aws" {
  region = var.region
}

module "honua" {
  transcript_signing            = var.transcript_signing
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
  existing_db_port                = var.existing_db_port
  existing_db_connection_string   = var.existing_db_connection_string
  db_publicly_accessible          = local.install_db_public
  db_additional_ingress_cidrs     = var.db_additional_ingress_cidrs
  enable_postgis                  = local.install_db_postgis
  postgis_readiness_max_attempts  = local.install_db_rdy_max
  postgis_readiness_sleep_seconds = local.install_db_rdy_sleep
  enable_rds_proxy                = var.enable_rds_proxy
  # Proxy headroom: the share of max_connections the proxy may open; the rest
  # stays for direct sessions (migrate/seed from the runner, PostGIS bootstrap).
  rds_proxy_max_connections_percent           = var.rds_proxy_max_connections_percent
  rds_proxy_max_idle_connections_percent      = var.rds_proxy_max_idle_connections_percent
  rds_proxy_connection_borrow_timeout_seconds = var.rds_proxy_connection_borrow_timeout_seconds
  redis_enabled                               = var.redis_enabled
  redis_connection_string                     = var.redis_connection_string
  redis_connection_cidrs                      = var.redis_connection_cidrs
  skip_migrations                             = var.skip_migrations
  migration_image                             = var.migration_image
  migration_packaged_manifest_sha256          = var.migration_packaged_manifest_sha256
  migration_target_locator_sha256             = var.migration_target_locator_sha256
  migration_create_secretsmanager_endpoint    = var.migration_create_secretsmanager_endpoint
  tags                                        = var.tags

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

  cors_allowed_origins                  = var.cors_allowed_origins
  operations_policy_rules               = var.operations_policy_rules
  studio_end_user_authorization         = var.studio_end_user_authorization
  import_background_job_threshold_bytes = var.import_background_job_threshold_bytes

  # Optional per-cell custom domain (custom-domain.tf).
  domain_name     = var.domain_name
  route53_zone_id = var.route53_zone_id
  public_base_url = var.public_base_url

  # GP on AWS Batch: the Lambda+Batch cell. use_batch_service_linked_role is
  # wired above with the other certification-cell inputs.
  gp_batch_retain_prior_definitions = var.gp_batch_retain_prior_definitions
  enable_gp_batch                   = var.enable_gp_batch
  gp_batch_image                    = var.gp_batch_image
  gp_batch_cpu_architecture         = var.gp_batch_cpu_architecture
  gp_batch_max_vcpus                = var.gp_batch_max_vcpus
  gp_batch_data_bucket_arn          = var.gp_batch_data_bucket_arn
  gp_batch_data_bucket_enabled      = var.gp_batch_data_bucket_enabled

  # Shared S3 file storage for the API Lambda and the GP Batch workers, so a
  # background import accepted by the Lambda can run on Batch.
  file_storage_provider           = var.file_storage_provider
  file_storage_aws_s3_bucket_name = var.file_storage_aws_s3_bucket_name
  file_storage_aws_s3_region      = var.file_storage_aws_s3_region
  file_storage_aws_s3_key_prefix  = var.file_storage_aws_s3_key_prefix

  platform_release = var.platform_release

  oidc_static_jwt = var.oidc_static_jwt

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
  description = "Public base URL: https://<domain_name> when the custom domain is configured, else the execute-api endpoint."
  value       = module.honua.service_url
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

output "file_storage_shared" {
  description = "Whether the API Lambda and the GP Batch job definitions share the S3 file storage bucket (file_storage_provider = AwsS3)."
  value       = module.honua.file_storage_shared
}

output "file_storage_environment_rendered" {
  description = "FileStorage__* settings rendered into the API Lambda (api), the control-plane event functions (control_plane) and the GP Batch job definitions (gp_batch)."
  value       = module.honua.file_storage_environment_rendered
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

output "rds_proxy_endpoint" {
  description = "RDS Proxy endpoint the Lambda functions and GP Batch jobs connect through when enable_rds_proxy is true; null otherwise. Migrations keep the direct endpoint (migrate_db_connection_secret_arn)."
  value       = module.honua.rds_proxy_endpoint
}

output "rds_proxy_arn" {
  description = "ARN of the RDS Proxy when enable_rds_proxy is true; null otherwise."
  value       = module.honua.rds_proxy_arn
}

# --- Out-of-band migration inputs ---------------------------------------------
# Serving functions skip migrations by default. A qualified isolated migration
# profile can gate their deployment; otherwise schema initialization must be
# completed separately before traffic. These outputs contain identifiers only.

output "migrate_required" {
  description = "True when schema initialization must be arranged separately before serving; false when the optional isolated migration profile gates deployment."
  value       = var.skip_migrations && var.migration_image == null
}

output "migration_contract" {
  description = "Pinned isolated migration invocation and verified receipt when the optional preview is enabled; null otherwise."
  value       = module.honua.migration_contract
  sensitive   = true
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
  value       = var.migration_image != null ? "The isolated migration profile gates serving deployment on its exact verified invocation receipt. Inspect migration_contract and independently verify runtime readiness after apply." : var.skip_migrations ? "Initialize the schema separately before traffic using a qualified isolated migration artifact and the direct migrate_db_connection_secret_arn plus migrate_* network identifiers. No matching public Lambda migration artifact is currently qualified. HTTP readiness alone is not a migration receipt." : "skip_migrations is false: serving cold starts attempt migrations; this is incompatible with the isolated migration profile."
}

output "gp_batch_prior_definitions_retained" {
  description = "Whether this stack retains prior Batch revisions; explicit cleanup is required after the rollback window."
  value       = module.honua.gp_batch_prior_definitions_retained
}
