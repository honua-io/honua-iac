# Optional per-cell custom domain for the API Gateway HTTP API (owner decision
# 11): the same inputs, under the same names, as the ECS root
# (examples/aws/variables.tf). The module owns the ACM certificate, its
# validation records, the API Gateway custom domain and mapping, and the
# Route53 alias; see modules/aws-serverless/custom-domain.tf.

variable "domain_name" {
  description = "Optional custom API hostname for ACM-managed TLS, an API Gateway custom domain and Route53 alias DNS (for example <run label>.cert.demo.honua.io). Set together with route53_zone_id."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID that owns domain_name when Terraform should manage certificate validation and the API Gateway alias DNS."
  type        = string
  default     = ""
}

output "api_endpoint" {
  description = "API Gateway execute-api endpoint, which stays enabled with or without a custom domain."
  value       = module.honua.api_endpoint
}

output "custom_domain_url" {
  description = "https://<domain_name> when the custom domain is configured, else null."
  value       = module.honua.custom_domain_url
}

output "custom_domain_alias_fqdn" {
  description = "FQDN of the module-owned Route53 alias record for the custom domain, else null."
  value       = module.honua.custom_domain_alias_fqdn
}

output "custom_domain_certificate_arn" {
  description = "ARN of the module-owned ACM certificate for the custom domain, else null."
  value       = module.honua.custom_domain_certificate_arn
}
