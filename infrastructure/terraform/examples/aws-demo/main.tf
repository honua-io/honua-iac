###############################################################################
# Phase-A Honua Demo Environment — demo.honua.io
#
# Lambda container (AOT) + API Gateway HTTP API + RDS db.t4g.small + PostGIS.
# No Redis (single-function, no distributed cache needed for a demo).
# No WAF: API Gateway HTTP API does not support WAFv2 association; rate-limiting
# is handled via API Gateway throttle settings (see throttle variables below).
# See README.md for DNS prerequisites before applying.
###############################################################################

locals {
  common_tags = merge({
    Project     = "honua-server"
    Environment = var.environment
    ManagedBy   = "terraform"
    Purpose     = "public-demo"
  }, var.tags)
}

# ---------------------------------------------------------------------------
# Honua Server — Lambda / API Gateway HTTP API
# ---------------------------------------------------------------------------

module "honua" {
  source = "../../modules/aws-serverless"

  # Identity
  name_prefix = var.name_prefix
  environment = var.environment

  # Lambda container — use the AOT image variant for fast cold starts
  image              = var.honua_image
  lambda_architectures = ["arm64"] # Graviton — cheaper and faster for .NET AOT
  lambda_memory_size = var.lambda_memory_size

  # No provisioned concurrency: cold starts are acceptable for a demo.
  # The AOT image keeps cold start latency short (~200–400 ms typical).
  lambda_reserved_concurrent_executions = null

  # Secrets
  admin_password = var.honua_admin_password

  # Database — db.t4g.small + PostGIS
  db_instance_class    = "db.t4g.small"
  db_allocated_storage = 20
  db_engine_version    = "15"
  db_password          = var.db_password
  db_require_ssl       = true
  db_multi_az          = false # single-AZ for demo cost
  enable_postgis       = true  # Required — Honua needs PostGIS + PostGIS Raster

  # Redis — disabled (single Lambda function, no distributed cache needed)
  redis_enabled = false

  # Networking — single NAT GW for cost savings on non-prod
  enable_nat_gateway = true
  single_nat_gateway = true

  # API Gateway throttling (replaces WAF; HTTP API does not support WAFv2)
  api_throttle_burst_limit = var.api_throttle_burst_limit
  api_throttle_rate_limit  = var.api_throttle_rate_limit

  # Log retention — shorter for demo to contain cost
  log_retention_days = 90

  # Demo-specific environment variables
  additional_env = {
    HONUA_SERVE_API_DOCS          = "true"
    HONUA_SERVE_STAC_DEMO         = "true"
    MultiTenancy__Enabled         = "true"
    MultiTenancy__DefaultTenantId = "public"
    # Allow the API Gateway custom domain as a valid host
    HostValidation__AllowedHosts__1 = "demo.honua.io"
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Custom domain — demo.honua.io
# ACM certificate, API Gateway custom domain, and Route53 record.
# The aws-serverless module does not manage custom domains; we provision them
# here, consistent with how the module exposes api_endpoint for the stage.
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "demo" {
  domain_name       = "demo.honua.io"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.common_tags
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.demo.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = var.route53_zone_id
}

resource "aws_acm_certificate_validation" "demo" {
  certificate_arn         = aws_acm_certificate.demo.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_apigatewayv2_domain_name" "demo" {
  domain_name = "demo.honua.io"

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.demo.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = local.common_tags
}

# Map the $default stage of the module's HTTP API to the custom domain.
# The module exposes the API endpoint URL; extract the API ID from it.
# api_endpoint format: https://<api-id>.execute-api.<region>.amazonaws.com
locals {
  api_id = regex("https://([^.]+)\\.execute-api", module.honua.api_endpoint)[0]
}

resource "aws_apigatewayv2_api_mapping" "demo" {
  api_id      = local.api_id
  domain_name = aws_apigatewayv2_domain_name.demo.id
  stage       = "$default"
}

resource "aws_route53_record" "demo" {
  name    = "demo.honua.io"
  type    = "A"
  zone_id = var.route53_zone_id

  alias {
    name                   = aws_apigatewayv2_domain_name.demo.domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.demo.domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}
