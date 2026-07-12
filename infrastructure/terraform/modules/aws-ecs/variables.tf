variable "name_prefix" {
  description = "Name prefix for resources."
  type        = string
  default     = "honua"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "tags" {
  description = "Additional tags to apply to resources."
  type        = map(string)
  default     = {}
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets."
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "existing_vpc_id" {
  description = "Existing VPC ID to reuse instead of creating a new VPC."
  type        = string
  default     = ""
}

variable "existing_vpc_cidr" {
  description = "CIDR block for existing_vpc_id. Required when reusing a VPC."
  type        = string
  default     = ""
}

variable "existing_public_subnet_ids" {
  description = "Public subnet IDs in existing_vpc_id. Required when reusing a VPC."
  type        = list(string)
  default     = []
}

variable "existing_private_subnet_ids" {
  description = "Private subnet IDs in existing_vpc_id. Required when reusing a VPC."
  type        = list(string)
  default     = []
}

variable "enable_nat_gateway" {
  description = "Whether to provision NAT gateways for private subnets."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway instead of one per AZ (cost savings for non-prod)."
  type        = bool
  default     = true
}

variable "container_port" {
  description = "Container port exposed by Honua Server."
  type        = number
  default     = 8080
}

variable "container_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 512
}

variable "container_memory" {
  description = "Fargate task memory (MiB)."
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Minimum number of ECS tasks. Values greater than 1 require deployment_mode=MultiNode with Redis and shared S3 file storage."
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum number of ECS tasks for auto-scaling. Values greater than 1 require deployment_mode=MultiNode with Redis and shared S3 file storage."
  type        = number
  default     = 1
}

variable "deployment_mode" {
  description = "Honua deployment mode. MultiNode is required whenever ECS can run more than one server task."
  type        = string
  default     = "SingleInstance"

  validation {
    condition     = contains(["SingleInstance", "MultiNode"], var.deployment_mode)
    error_message = "deployment_mode must be SingleInstance or MultiNode."
  }
}

variable "file_storage_provider" {
  description = "Honua file storage provider. MultiNode ECS deployments require AwsS3."
  type        = string
  default     = "Local"

  validation {
    condition     = contains(["Local", "AwsS3"], var.file_storage_provider)
    error_message = "file_storage_provider must be Local or AwsS3 for the AWS ECS module."
  }
}

variable "file_storage_aws_s3_bucket_name" {
  description = "Existing S3 bucket used for shared Honua file storage when file_storage_provider is AwsS3."
  type        = string
  default     = ""

  validation {
    condition     = var.file_storage_aws_s3_bucket_name == "" || can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.file_storage_aws_s3_bucket_name))
    error_message = "file_storage_aws_s3_bucket_name must be empty or a valid 3-63 character S3 bucket name."
  }
}

variable "file_storage_aws_s3_region" {
  description = "S3 bucket region. Leave empty to use the module AWS provider region."
  type        = string
  default     = ""
}

variable "file_storage_aws_s3_key_prefix" {
  description = "Optional key prefix for Honua objects in the shared S3 bucket."
  type        = string
  default     = "honua"
}

variable "assign_public_ip" {
  description = "Assign public IPs to tasks (only if using public subnets)."
  type        = bool
  default     = false
}

variable "image" {
  description = "Container image. Pin to an immutable release tag or digest; AOT builds are recommended for faster startup and lower memory."
  type        = string
}

variable "task_cpu_architecture" {
  description = "ECS/Fargate CPU architecture. Honua defaults to ARM64 for Graviton-friendly AWS deployments."
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], upper(var.task_cpu_architecture))
    error_message = "task_cpu_architecture must be ARM64 or X86_64."
  }
}

variable "admin_password" {
  description = "Admin API password for Honua (required in non-dev)."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.admin_password) >= 32
    error_message = "admin_password must be at least 32 characters."
  }
}

variable "connection_encryption_master_key" {
  description = "Master key for Honua connection encryption (Security__ConnectionEncryption__MasterKey). Leave null to auto-generate an independent key for new deployments. Existing deployments must pin their current key before upgrading; see the module README."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.connection_encryption_master_key == null || length(var.connection_encryption_master_key) >= 32
    error_message = "connection_encryption_master_key must be at least 32 characters when set."
  }
}

variable "db_username" {
  description = "PostgreSQL admin username."
  type        = string
  default     = "honua"
}

variable "db_password" {
  description = "PostgreSQL admin password. Leave null to auto-generate."
  type        = string
  sensitive   = true
  default     = null
}

variable "db_name" {
  description = "PostgreSQL database name."
  type        = string
  default     = "honua"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "RDS allocated storage in GB."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Maximum allocated storage in GB for RDS autoscaling."
  type        = number
  default     = 100
}

variable "db_engine_version" {
  description = "PostgreSQL engine version for RDS."
  type        = string
  default     = "15"
}

variable "db_publicly_accessible" {
  description = "Whether the RDS instance is publicly accessible."
  type        = bool
  default     = false
}

variable "db_additional_ingress_cidrs" {
  description = "Additional CIDRs allowed to access PostgreSQL (for controlled migration/PostGIS operations)."
  type        = list(string)
  default     = []
}

variable "db_multi_az" {
  description = "Enable Multi-AZ for RDS."
  type        = bool
  default     = false
}

variable "db_require_ssl" {
  description = "Append SSL requirements to the connection string."
  type        = bool
  default     = true
}

variable "existing_db_endpoint" {
  description = "Existing PostgreSQL endpoint to reuse. Set with existing_db_connection_string."
  type        = string
  default     = ""
}

variable "existing_db_connection_string" {
  description = "Existing PostgreSQL connection string to reuse. Set with existing_db_endpoint."
  type        = string
  default     = ""
  sensitive   = true
}

variable "allow_public_ingress_cidrs" {
  description = "DEPRECATED: use allow_https_ingress_cidrs and allow_http_ingress_cidrs."
  type        = list(string)
  default     = []
}

variable "allow_https_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB over HTTPS."
  type        = list(string)
  default     = []
}

variable "allow_http_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB over HTTP. When HTTPS redirect is enabled and this is empty, HTTPS CIDRs are reused."
  type        = list(string)
  default     = []
}

variable "alb_certificate_arn" {
  description = "ACM certificate ARN for HTTPS listener."
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Optional domain name for ACM-managed certificate."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for DNS validation (required with domain_name)."
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

variable "alb_enable_http_redirect" {
  description = "Enable HTTP -> HTTPS redirect listener on port 80."
  type        = bool
  default     = true
}

variable "alb_deletion_protection" {
  description = "Enable deletion protection on the ALB."
  type        = bool
  default     = true
}

variable "alb_drop_invalid_headers" {
  description = "Drop invalid HTTP headers at the ALB."
  type        = bool
  default     = true
}

variable "alb_access_logs_enabled" {
  description = "Enable ALB access logging."
  type        = bool
  default     = true
}

variable "alb_access_logs_bucket_name" {
  description = "Existing S3 bucket name for ALB access logs (leave empty to create one)."
  type        = string
  default     = ""
}

variable "alb_access_logs_prefix" {
  description = "S3 key prefix for ALB access logs."
  type        = string
  default     = "alb"
}

variable "alb_access_logs_force_destroy" {
  description = "Force destroy the ALB access logs bucket."
  type        = bool
  default     = false
}

variable "waf_web_acl_arn" {
  description = "Optional WAFv2 Web ACL ARN to associate with the ALB."
  type        = string
  default     = ""
}

variable "additional_env" {
  description = "Additional environment variables for the container."
  type        = map(string)
  default     = {}

  validation {
    condition = length(setintersection(toset([
      for key in keys(var.additional_env) : lower(replace(key, ":", "__"))
      ]), toset([
      "deployment__mode",
      "filestorage__provider",
      "filestorage__awss3__bucketname",
      "filestorage__awss3__region",
      "filestorage__awss3__keyprefix"
    ]))) == 0
    error_message = "Set deployment and file-storage settings through the typed module variables, not additional_env."
  }
}

variable "canary_enabled" {
  description = "Provision a secondary ECS service and ALB target group for canary rollouts."
  type        = bool
  default     = false
}

variable "canary_image" {
  description = "Optional image for the canary ECS service. Leave empty to reuse image."
  type        = string
  default     = ""
}

variable "canary_desired_count" {
  description = "Desired number of tasks for the canary ECS service when canary_enabled is true."
  type        = number
  default     = 1
}

variable "canary_weight_percentage" {
  description = "Percentage of default ALB traffic routed to the canary target group."
  type        = number
  default     = 0

  validation {
    condition     = var.canary_weight_percentage >= 0 && var.canary_weight_percentage <= 100
    error_message = "canary_weight_percentage must be between 0 and 100."
  }
}

variable "canary_additional_env" {
  description = "Additional environment variables merged into the canary ECS task definition."
  type        = map(string)
  default     = {}

  validation {
    condition = length(setintersection(toset([
      for key in keys(var.canary_additional_env) : lower(replace(key, ":", "__"))
      ]), toset([
      "deployment__mode",
      "filestorage__provider",
      "filestorage__awss3__bucketname",
      "filestorage__awss3__region",
      "filestorage__awss3__keyprefix"
    ]))) == 0
    error_message = "Set deployment and file-storage settings through the typed module variables, not canary_additional_env."
  }
}

variable "canary_header_name" {
  description = "HTTP header name used to force ALB routing to the canary service."
  type        = string
  default     = "X-Honua-Canary"

  validation {
    condition     = trimspace(var.canary_header_name) != ""
    error_message = "canary_header_name must not be empty."
  }
}

variable "canary_header_value" {
  description = "HTTP header value used to force ALB routing to the canary service."
  type        = string
  default     = "always"

  validation {
    condition     = trimspace(var.canary_header_value) != ""
    error_message = "canary_header_value must not be empty."
  }
}

variable "canary_listener_rule_priority" {
  description = "ALB listener rule priority for forced canary header routing."
  type        = number
  default     = 50

  validation {
    condition     = var.canary_listener_rule_priority >= 1 && var.canary_listener_rule_priority <= 50000
    error_message = "canary_listener_rule_priority must be between 1 and 50000."
  }
}

variable "redis_connection_string" {
  description = "Redis connection string for multi-node mode. Leave empty to create Redis."
  type        = string
  default     = ""
  sensitive   = true
}

variable "redis_connection_cidrs" {
  description = "Trusted CIDR ranges allowed for Redis egress when reusing an existing Redis endpoint."
  type        = list(string)
  default     = []
}

variable "redis_auth_token" {
  description = "Redis auth token (used when creating Redis). Leave empty to auto-generate."
  type        = string
  default     = ""
  sensitive   = true
}

variable "redis_enabled" {
  description = "Provision Redis (ElastiCache) for multi-node mode."
  type        = bool
  default     = true
}

variable "redis_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_engine_version" {
  description = "Redis engine version."
  type        = string
  default     = "7.0"
}

variable "redis_parameter_group_name" {
  description = "Redis parameter group name."
  type        = string
  default     = "default.redis7"
}

variable "redis_num_cache_clusters" {
  description = "Number of cache clusters in the replication group. Use 1 for lowest-cost validation; use >=2 for HA failover."
  type        = number
  default     = 1
}

variable "redis_port" {
  description = "Redis port."
  type        = number
  default     = 6379
}

variable "health_check_path" {
  description = "Path used by the ALB for health checks."
  type        = string
  default     = "/healthz/ready"
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days."
  type        = number
  default     = 365
}

variable "enable_container_insights" {
  description = "Enable ECS container insights."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "Existing KMS key ARN to use for logs and secrets (leave empty to create one)."
  type        = string
  default     = ""
}

variable "kms_key_deletion_window_days" {
  description = "KMS key deletion window (days)."
  type        = number
  default     = 30
}

variable "enable_postgis" {
  description = "Attempt to enable PostGIS and PostGIS Raster via local-exec (requires psql + network access)."
  type        = bool
  default     = false
}

variable "postgis_readiness_max_attempts" {
  description = "Maximum readiness attempts before PostGIS enablement fails."
  type        = number
  default     = 90

  validation {
    condition     = var.postgis_readiness_max_attempts >= 1
    error_message = "postgis_readiness_max_attempts must be at least 1."
  }
}

variable "postgis_readiness_sleep_seconds" {
  description = "Seconds to sleep between PostgreSQL readiness attempts."
  type        = number
  default     = 10

  validation {
    condition     = var.postgis_readiness_sleep_seconds >= 1
    error_message = "postgis_readiness_sleep_seconds must be at least 1."
  }
}
