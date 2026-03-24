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

variable "install" {
  description = "Provider-neutral install questionnaire for artifact, database, network, and storage settings. Legacy provider-specific variables remain supported as fallbacks."
  type = object({
    artifact = optional(object({
      image = optional(string)
      registry = optional(object({
        server      = optional(string)
        auth_mode   = optional(string)
        resource_id = optional(string)
      }))
    }))
    database = optional(object({
      host                    = optional(string)
      compute_sku             = optional(string)
      storage_gb              = optional(number)
      max_storage_gb          = optional(number)
      public_access           = optional(bool)
      postgis_enabled         = optional(bool)
      readiness_max_attempts  = optional(number)
      readiness_sleep_seconds = optional(number)
    }))
    network = optional(object({
      id                   = optional(string)
      cidr                 = optional(string)
      public_subnet_ids    = optional(list(string))
      private_subnet_ids   = optional(list(string))
      public_ingress_cidrs = optional(list(string))
      http_ingress_cidrs   = optional(list(string))
      https_ingress_cidrs  = optional(list(string))
    }))
    storage = optional(object({
      enabled        = optional(bool)
      name           = optional(string)
      container_name = optional(string)
      prefix         = optional(string)
      force_destroy  = optional(bool)
    }))
  })
  default = {}
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

variable "connection_encryption_master_key" {
  description = "Optional override for Security__ConnectionEncryption__MasterKey. Leave null to auto-generate an independent secret."
  type        = string
  sensitive   = true
  default     = null
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

variable "existing_db_cidrs" {
  description = "Trusted CIDR ranges allowed for PostgreSQL egress when reusing an existing database endpoint."
  type        = list(string)
  default     = []
}

variable "honua_image" {
  description = "Container image to deploy to ECS. Pin to an immutable release tag or digest."
  type        = string
  default     = null
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
  description = "Fargate task memory in MiB."
  type        = number
  default     = 1024
}

variable "task_cpu_architecture" {
  description = "Fargate CPU architecture for validation. ARM64 is the default."
  type        = string
  default     = "ARM64"
}

variable "db_publicly_accessible" {
  description = "Expose RDS publicly for integration testing."
  type        = bool
  default     = false
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

variable "db_maintenance_window" {
  description = "Preferred RDS maintenance window in Ddd:HH:MM-Ddd:HH:MM format."
  type        = string
  default     = "Sun:04:00-Sun:05:00"
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
  description = "Desired number of ECS tasks."
  type        = number
  default     = 1
}

variable "min_capacity" {
  description = "Minimum number of ECS tasks for autoscaling. Defaults to desired_count when null."
  type        = number
  default     = null
}

variable "max_capacity" {
  description = "Maximum number of ECS tasks for autoscaling."
  type        = number
  default     = 4
}

variable "autoscaling_cpu_target_value" {
  description = "Target average CPU utilization percentage for ECS autoscaling."
  type        = number
  default     = 70
}

variable "autoscaling_scale_in_cooldown_seconds" {
  description = "Cooldown in seconds after an ECS scale-in event."
  type        = number
  default     = 300
}

variable "autoscaling_scale_out_cooldown_seconds" {
  description = "Cooldown in seconds after an ECS scale-out event."
  type        = number
  default     = 60
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

variable "app_storage_enabled" {
  description = "Provision application S3 storage for validation and object-backed features."
  type        = bool
  default     = false
}

variable "app_storage_bucket_name" {
  description = "Optional explicit S3 bucket name for application storage."
  type        = string
  default     = ""
}

variable "app_storage_prefix" {
  description = "S3 key prefix for application storage probes."
  type        = string
  default     = "validation"
}

variable "app_storage_force_destroy" {
  description = "Force destroy the application S3 bucket when Terraform manages it."
  type        = bool
  default     = false
}
