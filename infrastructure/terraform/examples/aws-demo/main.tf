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

  # Declared here (rather than relying on the module default) because it is
  # also used for the VPC-endpoint security group and the in-VPC PostGIS
  # bootstrap (see vpc-endpoints.tf / postgis-bootstrap.tf).
  vpc_cidr = "10.0.0.0/16"
}

# ---------------------------------------------------------------------------
# Honua Server — Lambda / API Gateway HTTP API
# ---------------------------------------------------------------------------

module "honua" {
  source = "../../modules/aws-serverless"

  # Identity
  name_prefix = var.name_prefix
  environment = var.environment

  # Lambda container — use the AOT image variant for fast cold starts.
  # x86_64, not Graviton: the demo image is AOT-built on an amd64 workstation
  # and .NET AOT under QEMU arm64 emulation fails (MSBuild MSB4223 node spawn
  # error). Function and image architecture must match. Revisit when images
  # come from CI's native arm64 runners.
  image                = var.honua_image
  lambda_architectures = ["x86_64"]
  lambda_memory_size   = var.lambda_memory_size

  # No provisioned concurrency: cold starts are acceptable for a demo.
  # The AOT image keeps cold start latency short (~200–400 ms typical).
  #
  # Reserved concurrency 50 (2026-06-12, LIVE): was 20, set out-of-band in
  # the console as an emergency brake when browser tile bursts exhausted the
  # micro instance's connection slots (53300) — encoded here so applies stop
  # reverting it. 50 environments x Maximum Pool Size 4 = 200 direct
  # connections, under db.t4g.small's ~225-slot ceiling; bursts beyond 50
  # throttle at Lambda instead of 500ing every in-flight request.
  lambda_reserved_concurrent_executions = 50

  # 60 s bounds abandoned work: API Gateway gives up at 30 s, but the Lambda
  # keeps executing until this timeout. During seeding this was raised to 600
  # (the county-parcels synchronous import needs ~5 min); steady-state it must
  # stay LOW — a browser tile burst that outruns the db.t4g.micro otherwise
  # leaves a pile of orphaned multi-minute queries that starve the database
  # and 500 every later request. Raise temporarily for future bulk re-seeds.
  lambda_timeout_seconds = 60

  # Secrets
  admin_password = var.honua_admin_password

  # Database — db.t4g.small + PostGIS (upgraded from micro 2026-06-12 with
  # founder approval, APPLIED LIVE: tile bursts exhausted micro's ~112
  # connection slots — 4,400+ Npgsql 53300 errors in 48h while CPU never
  # passed 48%; small doubles memory and the max_connections formula
  # (~225 slots) for roughly +$12/mo).
  db_instance_class    = "db.t4g.small"
  db_allocated_storage = 20
  db_engine_version    = "15"
  db_password          = var.db_password
  db_require_ssl       = true
  db_multi_az          = false # single-AZ for demo cost
  db_apply_immediately = true  # demo: take resize outages now, not in the maintenance window

  # Npgsql pool tuning, LIVE in the connection-string secret since
  # 2026-06-12 (previously hand-edited there — an apply used to silently
  # revert it). Pool stays small on purpose: every Lambda execution
  # environment runs its own pool, so worst case is
  # reserved_concurrency x Maximum Pool Size connections.
  db_connection_string_options = "Maximum Pool Size=4;Connection Idle Lifetime=60;Connection Pruning Interval=30"

  # PostGIS + PostGIS Raster are required by Honua, but the module's
  # enable_postgis local-exec needs psql plus a network path to the private
  # RDS instance — neither exists here (no NAT, no VPN). The extensions are
  # installed by the in-VPC bootstrap Lambda instead (postgis-bootstrap.tf).
  enable_postgis = false

  # Run Honua's own schema migrations on startup for the initial deploy.
  # After the first successful boot this can be flipped back to true
  # (the serverless default) so cold starts skip the DbUp journal check.
  skip_migrations = true # runtime never migrates: concurrent cold starts each running migrations crash-looped the demo (2026-06-12); run migrations as a one-off job (set false only for a single first boot)

  # Let the in-VPC PostGIS bootstrap Lambda (its own security group) reach
  # PostgreSQL. The VPC is dedicated to this stack, so the VPC CIDR is the
  # tightest practical bound.
  vpc_cidr                    = local.vpc_cidr
  db_additional_ingress_cidrs = [local.vpc_cidr]

  # Redis — disabled (single Lambda function, no distributed cache needed)
  redis_enabled = false

  # Networking — no NAT gateway (~$33/mo + data saved). The public demo has
  # no OIDC and needs no general internet egress; the only AWS services the
  # Lambda needs at runtime are reached via VPC endpoints instead
  # (Secrets Manager interface endpoint + S3 gateway endpoint, see
  # vpc-endpoints.tf).
  enable_nat_gateway = false

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

    # FileStorage on S3 (see seed-data.tf): import staging for >10 MB vector
    # uploads and the PMTiles range proxy both resolve against this bucket.
    # Credentials are intentionally omitted so the AWS SDK falls back to the
    # Lambda execution role.
    FileStorage__Provider              = "AwsS3"
    FileStorage__AwsS3__BucketName     = local.data_bucket_name
    FileStorage__AwsS3__Region         = var.region
    FileStorage__AwsS3__ForcePathStyle = "false"
    # The demo contract serves the basemap at /api/v1/tiles/pmtiles/maui-basemap,
    # i.e. the artifact lives at the bucket root. "/" normalizes to an empty
    # publish prefix so the proxy accepts root-level artifact keys.
    FileStorage__PMTilesPublish__KeyPrefix = "/"

    # Request budget pairs with lambda_timeout_seconds above. Raise both to
    # 10 minutes temporarily for bulk synchronous re-seeds (county parcels
    # needs it); steady-state keep them tight so orphaned tile queries get
    # cancelled instead of starving db.t4g.micro for minutes after a burst.
    Limits__Connections__RequestTimeout = "00:01:00"

    # Application-level CORS so https://honua.io/demo.html can call
    # /rest/*, /ogc/*, and /api/v1/tiles/* (the /fonts route gets its CORS
    # header from the API Gateway integration mapping in seed-data.tf).
    Cors__AllowedOrigins__0 = "https://honua.io"
    Cors__AllowedOrigins__1 = "https://www.honua.io"
    # Local demo.html development/verification (python -m http.server 8123
    # in honua-site) — harmless for a public-data demo server.
    Cors__AllowedOrigins__2 = "http://localhost:8123"
    Cors__AllowCredentials  = "false"
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

# Alias target switches between the CloudFront distribution (steady state)
# and the API Gateway custom domain (pre-CDN validation) — see cloudfront.tf
# for the locals and the DNS swap sequencing notes.
resource "aws_route53_record" "demo" {
  name    = "demo.honua.io"
  type    = "A"
  zone_id = var.route53_zone_id

  alias {
    name                   = local.demo_alias_name
    zone_id                = local.demo_alias_zone
    evaluate_target_health = false
  }
}
