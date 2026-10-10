# Optional per-cell custom domain for the API Gateway HTTP API (owner decision
# 11, 2026-10-10): the same domain_name / route53_zone_id inputs and the same
# managed-certificate pattern modules/aws-ecs uses for its ALB (iac#229).
#
# When both inputs are set the module owns, and terraform destroy removes:
# - an ACM certificate for domain_name, DNS-validated in route53_zone_id,
# - its validation CNAME records,
# - a REGIONAL API Gateway custom domain (TLS 1.2 policy) mapped to the
#   $default stage,
# - a Route53 alias A record from domain_name to that custom domain.
# The execute-api endpoint stays enabled; honua_url / service_url switch to
# https://<domain_name>. The Lambda function, its alias and any Function URL
# are untouched.
#
# Server-side behaviour behind the custom domain:
# - Host validation: the Lambda allowlists only *.execute-api.<region>... (see
#   lambda_environment in main.tf). API Gateway passes the client's Host (the
#   custom domain) in the payload-2.0 event and Lambda Web Adapter replays it,
#   so domain_name is appended to HostValidation__AllowedHosts or every
#   request on the custom domain is a 400 "Invalid Host header". This is the
#   one environment entry the domain adds (~80 bytes against the 4 KB cap,
#   checked by the lambda_environment_bytes precondition).
# - HSTS: already emitted unconditionally (SecurityHeaders__HstsHttpsOnly =
#   "false" in lambda_environment), which is what modules/aws-ecs sets in
#   local.alb_tls_environment once its ALB terminates TLS. Nothing to add.
# - Forwarded headers: API Gateway sets X-Forwarded-Proto: https and Lambda Web
#   Adapter forwards it, but this module does not set
#   ASPNETCORE_FORWARDEDHEADERS_ENABLED (ECS does), on the custom domain or on
#   execute-api. honua-server never derives link origins from the request
#   Host/scheme (BaseUrlResolver uses Public:BaseUrl / PUBLIC_BASE_URL or a
#   loopback origin) and HSTS does not depend on the scheme here, so it is not
#   required for the domain; operators who need absolute links set
#   Public__BaseUrl through additional_env as on ECS.
# - CORS: the API Gateway cors_configuration belongs to the API, so it applies
#   identically on the custom domain and on execute-api.

locals {
  use_custom_domain = var.domain_name != "" && var.route53_zone_id != ""

  # Host-validation allowlist entries beyond the execute-api wildcard.
  lambda_additional_allowed_hosts = concat(
    var.additional_allowed_hosts,
    local.use_custom_domain && !contains(var.additional_allowed_hosts, var.domain_name) ? [var.domain_name] : [],
  )

  custom_domain_url = local.use_custom_domain ? "https://${var.domain_name}" : null
}

variable "domain_name" {
  description = "Optional custom API hostname. With route53_zone_id, the module creates a DNS-validated ACM certificate, a regional API Gateway custom domain mapped to the $default stage, and a Route53 alias record, and service_url becomes https://<domain_name>. Same input as modules/aws-ecs."
  type        = string
  default     = ""

  validation {
    condition     = var.domain_name == "" || can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?[.])+[a-z]{2,63}$", var.domain_name))
    error_message = "domain_name must be a lower-case fully qualified host name (for example run-123.cert.demo.honua.io) or empty."
  }
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID that owns domain_name, for certificate validation and the alias record (required with domain_name). Same input as modules/aws-ecs."
  type        = string
  default     = ""
}

# Half a configuration creates nothing (as on modules/aws-ecs); surface it.
check "custom_domain_inputs" {
  assert {
    condition     = (var.domain_name == "") == (var.route53_zone_id == "")
    error_message = "domain_name and route53_zone_id must be set together; with only one of them no custom domain is created and service_url stays on execute-api."
  }
}

resource "aws_acm_certificate" "api" {
  count             = local.use_custom_domain ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"
  tags              = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "api_cert_validation" {
  for_each = local.use_custom_domain ? {
    for dvo in aws_acm_certificate.api[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "api" {
  count                   = local.use_custom_domain ? 1 : 0
  certificate_arn         = aws_acm_certificate.api[0].arn
  validation_record_fqdns = [for record in aws_route53_record.api_cert_validation : record.fqdn]
}

resource "aws_apigatewayv2_domain_name" "this" {
  count       = local.use_custom_domain ? 1 : 0
  domain_name = var.domain_name

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.api[0].certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = local.tags
}

resource "aws_apigatewayv2_api_mapping" "this" {
  count       = local.use_custom_domain ? 1 : 0
  api_id      = aws_apigatewayv2_api.this.id
  domain_name = aws_apigatewayv2_domain_name.this[0].id
  stage       = aws_apigatewayv2_stage.this.id
}

resource "aws_route53_record" "api_alias" {
  count   = local.use_custom_domain ? 1 : 0
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

output "custom_domain_name" {
  description = "Custom API hostname when domain_name and route53_zone_id are set, else null."
  value       = local.use_custom_domain ? var.domain_name : null
}

output "custom_domain_url" {
  description = "https://<domain_name> when the custom domain is configured, else null."
  value       = local.custom_domain_url
}

output "custom_domain_alias_fqdn" {
  description = "FQDN of the module-owned Route53 alias record for the custom domain, else null."
  value       = local.use_custom_domain ? aws_route53_record.api_alias[0].fqdn : null
}

output "custom_domain_certificate_arn" {
  description = "ARN of the module-owned ACM certificate for the custom domain, else null."
  value       = local.use_custom_domain ? aws_acm_certificate.api[0].arn : null
}

output "service_url" {
  description = "Public base URL of the API: the https custom domain when configured, else the execute-api endpoint (api_endpoint)."
  value       = coalesce(local.custom_domain_url, aws_apigatewayv2_api.this.api_endpoint)
}
