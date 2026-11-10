variable "static_console" {
  description = "Static Console at /console/ on domain_name; viewer ACM certificate must be issued in us-east-1 and cover the same hostname as the regional ALB certificate. Upload the verified bundle separately."
  type = object({
    viewer_certificate_arn = string
    bundle_version         = string
    web_acl_id             = optional(string)
  })
  default = null
}

variable "file_storage_aws_s3_create_bucket" {
  description = "Create a private versioned bucket for shared file storage. Requires file_storage_provider=AwsS3 and no supplied bucket name."
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
  default     = "cache.t4g.micro"
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
output "file_storage_bucket" {
  value       = module.honua.file_storage_bucket
  description = "Shared storage bucket."
}
