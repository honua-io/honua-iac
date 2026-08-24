variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name used in resource naming."
  type        = string
  default     = "it"
}

variable "name_prefix" {
  description = "Prefix used for resource names."
  type        = string
  default     = "honuaecs"
}

variable "existing_vpc_id" {
  description = "Existing VPC ID to reuse."
  type        = string
  default     = ""
}

variable "existing_vpc_cidr" {
  description = "CIDR for existing_vpc_id."
  type        = string
  default     = ""
}

variable "existing_public_subnet_ids" {
  description = "Public subnet IDs in existing_vpc_id."
  type        = list(string)
  default     = []
}

variable "existing_private_subnet_ids" {
  description = "Private subnet IDs in existing_vpc_id."
  type        = list(string)
  default     = []
}

variable "honua_admin_password" {
  description = "Admin password for Honua."
  type        = string
  sensitive   = true
}

variable "honua_connection_encryption_master_key" {
  description = "Required connection-key decision. Set null only for a new deployment; existing deployments must set their current key before upgrading."
  type        = string
  sensitive   = true
  nullable    = true
}

variable "db_password" {
  description = "PostgreSQL admin password used for deterministic integration tests."
  type        = string
  sensitive   = true
  default     = null
}

variable "existing_db_endpoint" {
  description = "Existing PostgreSQL endpoint to reuse."
  type        = string
  default     = ""
}

variable "existing_db_connection_string" {
  description = "Existing PostgreSQL connection string to reuse."
  type        = string
  sensitive   = true
  default     = ""
}

variable "honua_image" {
  description = "Container image to deploy to ECS. Pin to an immutable release tag or digest."
  type        = string
}

variable "operator_contract_identity" {
  description = "Optional immutable identity inputs for the honua.operator-contract/v1 output. Omit only for disposable, unqualified development plans; certified consumers must provide every required digest and backend/state lineage input."
  type = object({
    candidate_digest      = string
    iac_revision          = string
    terraform_version     = string
    provider_lock_digest  = string
    image_digest          = string
    backend_config_digest = optional(string)
    state_lineage         = optional(string)
    state_serial          = optional(number)
    workload_identity     = optional(string)
  })
  default = null

  validation {
    condition = var.operator_contract_identity == null || (
      can(regex("^[0-9a-f]{64}$", var.operator_contract_identity.candidate_digest)) &&
      can(regex("^([0-9a-f]{40}|[0-9a-f]{64})$", var.operator_contract_identity.iac_revision)) &&
      trimspace(var.operator_contract_identity.terraform_version) != "" &&
      can(regex("^[0-9a-f]{64}$", var.operator_contract_identity.provider_lock_digest)) &&
      can(regex("^sha256:[0-9a-f]{64}$", var.operator_contract_identity.image_digest)) &&
      (try(var.operator_contract_identity.backend_config_digest, null) == null || can(regex("^[0-9a-f]{64}$", var.operator_contract_identity.backend_config_digest))) &&
      (try(var.operator_contract_identity.state_lineage, null) == null || can(regex("^[0-9a-f-]{36}$", var.operator_contract_identity.state_lineage))) &&
      (try(var.operator_contract_identity.state_serial, null) == null || var.operator_contract_identity.state_serial >= 0)
    )
    error_message = "operator_contract_identity must use SHA-256 digests, a 40/64-character IaC revision, a sha256 image digest, and non-negative state serial when supplied."
  }
}

variable "ai_provider_secret_arn" {
  description = "Optional customer-owned Secrets Manager ARN containing HONUA_AI_PROVIDER_API_KEY. The stack references but never creates, reads, or deletes this secret."
  type        = string
  default     = ""
}

variable "ai_provider_secret_kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for ai_provider_secret_arn."
  type        = string
  default     = ""
}

variable "task_cpu_architecture" {
  description = "Fargate CPU architecture. X86_64 is the release-certified default."
  type        = string
  default     = "X86_64"
}

variable "db_publicly_accessible" {
  description = "Expose RDS publicly for integration testing."
  type        = bool
  default     = false
}

variable "db_additional_ingress_cidrs" {
  description = "Extra CIDRs allowed to connect to Postgres."
  type        = list(string)
  default     = []
}

variable "enable_postgis" {
  description = "Enable PostGIS and PostGIS Raster during apply."
  type        = bool
  default     = true
}

variable "postgis_readiness_max_attempts" {
  description = "Maximum readiness attempts before PostGIS enablement fails."
  type        = number
  default     = 90
}

variable "postgis_readiness_sleep_seconds" {
  description = "Seconds to sleep between PostgreSQL readiness attempts."
  type        = number
  default     = 10
}

variable "redis_enabled" {
  description = "Provision ElastiCache Redis."
  type        = bool
  default     = true
}

variable "redis_connection_string" {
  description = "Existing Redis connection string to reuse."
  type        = string
  sensitive   = true
  default     = ""
}

variable "redis_connection_cidrs" {
  description = "Trusted CIDR ranges allowed for Redis egress when reusing an existing Redis endpoint."
  type        = list(string)
  default     = []
}

variable "desired_count" {
  description = "Minimum number of ECS tasks. Values greater than 1 require the safe MultiNode inputs."
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum ECS auto-scaling capacity. Values greater than 1 require the safe MultiNode inputs."
  type        = number
  default     = 1
}

variable "deployment_mode" {
  description = "Honua deployment mode. Use MultiNode only with Redis and shared S3 file storage."
  type        = string
  default     = "SingleInstance"
}

variable "file_storage_provider" {
  description = "Honua file storage provider (Local or AwsS3)."
  type        = string
  default     = "Local"
}

variable "file_storage_aws_s3_bucket_name" {
  description = "Existing S3 bucket for shared Honua file storage."
  type        = string
  default     = ""
}

variable "file_storage_aws_s3_region" {
  description = "S3 bucket region. Leave empty to use region."
  type        = string
  default     = ""
}

variable "file_storage_aws_s3_key_prefix" {
  description = "Optional key prefix for Honua objects."
  type        = string
  default     = "honua"
}

variable "canary_enabled" {
  description = "Provision the optional ALB canary ECS service."
  type        = bool
  default     = false
}

variable "canary_image" {
  description = "Optional canary image override."
  type        = string
  default     = ""
}

variable "canary_desired_count" {
  description = "Desired number of ECS tasks in the canary service."
  type        = number
  default     = 1
}

variable "canary_weight_percentage" {
  description = "Percentage of default ALB traffic routed to the canary target group."
  type        = number
  default     = 0
}

variable "alb_deletion_protection" {
  description = "Enable ALB deletion protection."
  type        = bool
  default     = true
}

variable "alb_access_logs_enabled" {
  description = "Enable ALB access logs."
  type        = bool
  default     = true
}

variable "alb_access_logs_force_destroy" {
  description = "Force destroy ALB access logs bucket when managed by this stack."
  type        = bool
  default     = true
}

variable "alb_certificate_arn" {
  description = "ACM certificate ARN for the ALB HTTPS listener."
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Optional custom API hostname for ACM-managed TLS and Route53 ALB alias DNS."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID that owns domain_name when Terraform should manage certificate validation and ALB alias DNS."
  type        = string
  default     = ""
}

variable "domain_alias_record_enabled" {
  description = "Create a Route53 alias A record from domain_name to the ALB when domain_name and route53_zone_id are set."
  type        = bool
  default     = true
}

variable "subject_alternative_names" {
  description = "Subject alternative names for the ACM certificate."
  type        = list(string)
  default     = []
}

variable "allow_https_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB over HTTPS during validation."
  type        = list(string)
  default     = []
}

variable "allow_http_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB over HTTP during validation."
  type        = list(string)
  default     = []
}

variable "waf_web_acl_arn" {
  description = "Optional WAFv2 Web ACL ARN associated to the ALB."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags for resources."
  type        = map(string)
  default     = {}
}
