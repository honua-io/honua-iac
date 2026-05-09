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
