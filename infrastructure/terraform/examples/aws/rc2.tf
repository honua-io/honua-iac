variable "static_console" {
  description = "Static Console at /console/ on domain_name; viewer ACM certificate must be issued in us-east-1 and cover the same hostname as the regional ALB certificate. Upload the verified bundle separately."
  type = object({
    viewer_certificate_arn = string
    bundle_version         = string
    web_acl_id             = optional(string)
  })
  default = null
}

variable "cdn" {
  description = "CloudFront distribution on domain_name in front of the load balancer; the deployment's shared cache. The viewer ACM certificate must be issued in us-east-1 and cover domain_name."
  type = object({
    viewer_certificate_arn = string
    web_acl_id             = optional(string)
    price_class            = optional(string, "PriceClass_100")
    access_logs = optional(object({
      bucket_domain_name = string
      prefix             = optional(string, "")
    }))
  })
  default = null
}

variable "autoscaling_requests_per_target" {
  description = "Average load-balancer requests per task per minute held by request-count target tracking, alongside the CPU policy. Null scales on CPU only."
  type        = number
  default     = null
}

variable "shared_state_backend" {
  description = "redis (default) requires Redis before more than one task may run. postgres declares that the deployed server release keeps shared state in PostgreSQL, so more than one task may run without Redis."
  type        = string
  default     = "redis"
}

variable "db_instance_class" {
  description = "RDS instance class. It bounds the per-task database pool at the maximum task count; see the db_connection_budget output."
  type        = string
  default     = "db.t3.micro"
}

variable "file_storage_aws_s3_create_bucket" {
  description = "Create a private versioned bucket for shared file storage. Requires file_storage_provider=AwsS3 and no supplied bucket name."
  type        = bool
  default     = false
}

variable "file_storage_aws_s3_force_destroy" {
  description = "Let destroy delete the created file storage bucket together with every object and version in it. For disposable stacks only."
  type        = bool
  default     = false
}

variable "postgis_bootstrap_image" {
  description = "Optional immutable PostgreSQL client image (psql entrypoint) for in-VPC PostGIS initialization before every server/migrator start. Null preserves the runner-based enable_postgis behavior."
  type        = string
  default     = null
}

variable "redis_node_type" {
  type        = string
  default     = "cache.t3.micro"
  description = "Managed ElastiCache node size."
}
variable "db_engine_version" {
  type        = string
  default     = "15"
  description = "RDS PostgreSQL engine version."
}
output "static_console" {
  value       = module.honua.static_console
  description = "Console upload target and HTTPS URL."
}
output "cdn" {
  value       = module.honua.cdn
  description = "CloudFront distribution id, ARN, domain and URL."
}
output "db_connection_budget" {
  value       = module.honua.db_connection_budget
  description = "Per-task database pool size and the worst-case connection total at the maximum task count."
}
output "file_storage_bucket" {
  value       = module.honua.file_storage_bucket
  description = "Shared storage bucket."
}
