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
  description = "Lambda container image URI (ECR). Must be a *-lambda-aot tag for AOT performance. Pin to an immutable release tag or digest."
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

variable "lambda_memory_size" {
  description = "Lambda memory in MB. 1024 MB is the default and sufficient for demo traffic. Increase to 2048 for larger payloads."
  type        = number
  default     = 1024
}

variable "api_throttle_burst_limit" {
  description = "API Gateway burst throttle limit (max concurrent requests). Replaces WAF rate-limiting — HTTP API does not support WAFv2."
  type        = number
  default     = 200
}

variable "api_throttle_rate_limit" {
  description = "API Gateway steady-state throttle limit (requests per second). Conservative default for a public demo."
  type        = number
  default     = 50
}

variable "route_demo_dns_to_cloudfront" {
  description = "Point the demo.honua.io A/AAAA alias at the CloudFront distribution (true, steady state) or directly at the API Gateway custom domain (false — used to validate a fresh distribution via its *.cloudfront.net domain before swapping DNS)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
