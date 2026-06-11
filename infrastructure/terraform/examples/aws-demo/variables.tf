variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name used in resource naming."
  type        = string
  default     = "demo"
}

variable "name_prefix" {
  description = "Prefix used for resource names."
  type        = string
  default     = "honua-demo"
}

variable "honua_image" {
  description = "Container image to deploy to ECS. Pin to an immutable release tag or digest (AOT build recommended)."
  type        = string
}

variable "honua_admin_password" {
  description = "Admin API password for Honua (minimum 32 characters; also used as Security__ConnectionEncryption__MasterKey)."
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "PostgreSQL admin password. Leave null to auto-generate."
  type        = string
  sensitive   = true
  default     = null
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for demo.honua.io. Required — see DNS prerequisites in README."
  type        = string
}

variable "waf_api_limit_per_5m" {
  description = "Per-IP request limit per 5-minute window for /rest, /ogc, and /odata API paths."
  type        = number
  default     = 2000
}

variable "waf_admin_limit_per_5m" {
  description = "Per-IP request limit per 5-minute window for /admin paths."
  type        = number
  default     = 300
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
