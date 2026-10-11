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
#   Host/scheme and HSTS does not depend on the scheme here, so it is not
#   required for the domain.
# - Public base URL: honua-server builds absolute links (publication URLs,
#   OGC/STAC self links, admin OIDC redirect URIs) only from Public:BaseUrl /
#   PUBLIC_BASE_URL (BaseUrlResolver); without it they fall back to a loopback
#   origin, and admin OIDC refuses to start outside Development. The custom
#   domain therefore also sets Public__BaseUrl = https://<domain_name> (one more
#   entry, about 30 bytes plus the host name, against the same 4 KB cap). An
#   explicit public_base_url wins over the domain, and a Public__BaseUrl or
#   PUBLIC_BASE_URL already in additional_env wins over both, so existing
#   operator settings are kept. The server ignores a value without an http(s)
#   scheme, so public_base_url is validated as an absolute URL.
# - CORS: the server answers CORS (API Gateway has no cors_configuration), so
#   it behaves identically on the custom domain and on execute-api.
#
# Nothing here assumes a particular DNS suffix: domain_name is any customer
# FQDN (any TLD, including IDN/punycode xn-- labels) in a hosted zone the
# operator owns.

locals {
  use_custom_domain = var.domain_name != "" && var.route53_zone_id != ""

  # Host-validation allowlist entries beyond the execute-api wildcard.
  lambda_additional_allowed_hosts = concat(
    var.additional_allowed_hosts,
    local.use_custom_domain && !contains(var.additional_allowed_hosts, var.domain_name) ? [var.domain_name] : [],
  )

  custom_domain_url = local.use_custom_domain ? "https://${var.domain_name}" : null

  # Public:BaseUrl for server-built absolute links (see the header comment).
  additional_env_sets_public_base_url = length(setintersection(
    toset([for name in(var.additional_env == null ? [] : keys(var.additional_env)) : lower(replace(name, ":", "__"))]),
    toset(["public__baseurl", "public_base_url"]),
  )) > 0
  public_base_url = trimsuffix(var.public_base_url, "/") != "" ? trimsuffix(var.public_base_url, "/") : (
    local.use_custom_domain ? local.custom_domain_url : ""
  )
  public_base_url_environment = local.public_base_url != "" && !local.additional_env_sets_public_base_url ? {
    Public__BaseUrl = local.public_base_url
  } : {}
}

variable "domain_name" {
  description = "Optional custom API hostname. With route53_zone_id, the module creates a DNS-validated ACM certificate, a regional API Gateway custom domain mapped to the $default stage, and a Route53 alias record, and service_url becomes https://<domain_name>. Same input as modules/aws-ecs."
  type        = string
  default     = ""

  validation {
    condition     = var.domain_name == "" || can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?[.])+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$", var.domain_name))
    error_message = "domain_name must be a lower-case fully qualified host name on any domain you own (for example gis.example.com, or a punycode xn-- name) or empty."
  }
}

variable "public_base_url" {
  description = "Public origin honua-server uses for absolute links (Public__BaseUrl), for example https://gis.example.com or https://example.org/gis. Empty (default) uses https://<domain_name> when the custom domain is configured and sets nothing otherwise. Set it when clients reach the API through another front door (a CDN or proxy on your own domain). A Public__BaseUrl or PUBLIC_BASE_URL in additional_env takes precedence."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.public_base_url == "" || can(regex("^https?://[^/?#@[:space:]]+(/[^?#[:space:]]*)?$", var.public_base_url))
    error_message = "public_base_url must be an absolute http(s) URL such as https://gis.example.com, without query, fragment or credentials: honua-server ignores a bare host name and falls back to loopback links."
  }
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID that owns domain_name, for certificate validation and the alias record (required with domain_name). Same input as modules/aws-ecs."
  type        = string
  default     = ""
}

check "public_base_url_single_source" {
  assert {
    condition     = var.public_base_url == "" || !local.additional_env_sets_public_base_url
    error_message = "public_base_url is ignored because additional_env already sets Public__BaseUrl or PUBLIC_BASE_URL; set the public origin in one place."
  }
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

# Keyed by the certificate's (only) domain, which is known at plan time, rather
# than by domain_validation_options, which a first plan may not know yet; the
# record values are looked up from the options at apply.
resource "aws_route53_record" "api_cert_validation" {
  for_each = local.use_custom_domain ? toset([var.domain_name]) : toset([])

  zone_id = var.route53_zone_id
  name    = one([for dvo in aws_acm_certificate.api[0].domain_validation_options : dvo.resource_record_name if dvo.domain_name == each.key])
  type    = one([for dvo in aws_acm_certificate.api[0].domain_validation_options : dvo.resource_record_type if dvo.domain_name == each.key])
  records = [one([for dvo in aws_acm_certificate.api[0].domain_validation_options : dvo.resource_record_value if dvo.domain_name == each.key])]
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

output "public_base_url" {
  description = "Public__BaseUrl the module rendered into the Lambda environment (public_base_url, else https://<domain_name>), or null when it sets none."
  value       = lookup(local.public_base_url_environment, "Public__BaseUrl", null)
}
