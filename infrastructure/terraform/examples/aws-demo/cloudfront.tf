###############################################################################
# CloudFront CDN in front of demo.honua.io — tile caching at the edge.
#
# API Gateway + Lambda + RDS handle demo traffic fine, but tile
# bursts (a visitor panning the map) fan out into dozens of concurrent Lambda
# invocations and database reads for bytes that never change between reseeds.
# CloudFront absorbs those:
#   - LONG cache (24 h) on the immutable tile/glyph routes, including the
#     PMTiles range proxy (CloudFront caches range GETs natively).
#   - NO cache on everything else (queries, OData, admin, healthz) — the
#     default behavior passes through with all headers and query strings.
#
# The origin is the *regional execute-api endpoint*, NOT demo.honua.io —
# the Route53 record for demo.honua.io is repointed at this distribution, so
# using it as the origin would loop. The API Gateway custom-domain target
# (d-xxxx.execute-api...) is also unusable as an origin: it only serves the
# demo.honua.io ACM cert, and CloudFront validates the origin TLS cert
# against the origin domain name.
#
# A response-headers policy stamps the demo's CORS headers on the cached
# behaviors at the edge (mirroring the server's Cors__* config in main.tf).
# This also masks honua-server#1627 (missing CORS headers on error
# responses) for the cached routes.
#
# DNS swap sequencing: apply with -var=route_demo_dns_to_cloudfront=false
# first, validate the distribution via its *.cloudfront.net domain, then
# apply with the default (true) to repoint demo.honua.io.
###############################################################################

# CloudFront viewer certificates must live in us-east-1 regardless of where
# the rest of the stack runs.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

locals {
  # Regional execute-api endpoint as a bare hostname (the module exposes the
  # full URL; aws_cloudfront_distribution wants just the domain).
  api_origin_domain = replace(module.honua.api_endpoint, "https://", "")

  # Tile/glyph routes that are safe to cache for 24 h. Shapes match the
  # honua-server endpoint registry (docs/gis/* matrices):
  #   /api/v1/tiles/...                                   PMTiles range proxy
  #   /ogc/tiles/...                                      OGC API Tiles
  #   /rest/services/{id}/MapServer/tile/{z}/{y}/{x}      GeoServices map tiles
  #   /rest/services/{id}/ImageServer/tile/{l}/{r}/{c}    GeoServices image tiles
  #   /fonts/{fontstack}/{range}.pbf                      SDF glyphs (S3 proxy)
  #   /terrain/{datasetId}/...                            Terrain-RGB tiles
  cached_path_patterns = [
    "/api/v1/tiles/*",
    "/ogc/tiles/*",
    "/rest/services/*/MapServer/tile/*",
    "/rest/services/*/ImageServer/tile/*",
    "/fonts/*",
    "/terrain/*",
  ]

  # Route53 alias target for demo.honua.io (consumed by main.tf):
  # CloudFront once validated, API Gateway custom domain until then.
  demo_alias_name = var.route_demo_dns_to_cloudfront ? aws_cloudfront_distribution.demo.domain_name : aws_apigatewayv2_domain_name.demo.domain_name_configuration[0].target_domain_name
  demo_alias_zone = var.route_demo_dns_to_cloudfront ? aws_cloudfront_distribution.demo.hosted_zone_id : aws_apigatewayv2_domain_name.demo.domain_name_configuration[0].hosted_zone_id
}

# ---------------------------------------------------------------------------
# Viewer certificate (us-east-1). The DNS validation CNAME for demo.honua.io
# already exists (aws_route53_record.cert_validation in main.tf — ACM issues
# identical validation records for the same domain in every region), so this
# cert validates against the existing record instead of creating a duplicate.
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "demo_cloudfront" {
  provider = aws.us_east_1

  domain_name       = "demo.honua.io"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.common_tags
}

resource "aws_acm_certificate_validation" "demo_cloudfront" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.demo_cloudfront.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ---------------------------------------------------------------------------
# Cache / origin-request / response-headers policies
# ---------------------------------------------------------------------------

# Long cache for immutable tile bytes. Tiles only change on reseed, and the
# README documents the create-invalidation step for that. min_ttl stays 0 so
# the origin can still opt out per-response with Cache-Control if it ever
# needs to; with no Cache-Control header (current behavior) the 24 h default
# applies. Query strings are part of the cache key (?f=json style format
# switches on the GeoServices/OGC routes return different bytes).
resource "aws_cloudfront_cache_policy" "tiles" {
  name    = "${var.name_prefix}-${var.environment}-tiles-24h"
  comment = "24h TTL for Honua demo tile/glyph routes"

  min_ttl     = 0
  default_ttl = 86400
  max_ttl     = 86400

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "all"
    }
  }
}

# Forward everything except Host on every behavior. Host must NOT reach the
# origin: API Gateway routes by Host header, and the execute-api endpoint
# only answers for its own hostname. (Range and Origin headers pass through
# via this policy, which the PMTiles proxy and app CORS rely on.)
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# Pass-through (default behavior): no caching at all.
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# Edge CORS for the cached behaviors, mirroring the server's CORS config
# (Cors__AllowedOrigins__* in main.tf + CorsConfiguration.cs defaults).
# Cached responses are shared across requesting origins, so the headers must
# be stamped per-response at the edge rather than trusted from the cache;
# origin_override also masks honua-server#1627 (no CORS on error responses)
# for these routes.
resource "aws_cloudfront_response_headers_policy" "demo_cors" {
  name    = "${var.name_prefix}-${var.environment}-tile-cors"
  comment = "CORS for cached Honua demo tile routes"

  cors_config {
    access_control_allow_credentials = false

    access_control_allow_origins {
      items = [
        "https://honua.io",
        "https://www.honua.io",
        "http://localhost:8123",
      ]
    }

    access_control_allow_methods {
      items = ["GET", "HEAD", "OPTIONS"]
    }

    access_control_allow_headers {
      items = [
        "Content-Type",
        "Authorization",
        "X-API-Key",
        "X-Correlation-ID",
        "Range",
        "If-Range",
        "If-None-Match",
        "If-Modified-Since",
      ]
    }

    access_control_expose_headers {
      items = [
        "Accept-Ranges",
        "Content-Range",
        "Content-Length",
        "ETag",
        "Last-Modified",
      ]
    }

    # Matches the server's SetPreflightMaxAge default (5 minutes).
    access_control_max_age_sec = 300

    origin_override = true
  }
}

# ---------------------------------------------------------------------------
# Distribution
# ---------------------------------------------------------------------------

resource "aws_cloudfront_distribution" "demo" {
  enabled         = true
  comment         = "Honua demo CDN — tile caching for demo.honua.io"
  aliases         = ["demo.honua.io"]
  price_class     = "PriceClass_100" # NA + EU edges are plenty for a demo
  http_version    = "http2and3"
  is_ipv6_enabled = true

  origin {
    origin_id   = "honua-api-gateway"
    domain_name = local.api_origin_domain

    custom_origin_config {
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      http_port              = 80
      https_port             = 443
      # API Gateway gives up at 30 s; don't hold edge connections longer.
      origin_read_timeout      = 30
      origin_keepalive_timeout = 5
    }
  }

  # Tile/glyph routes — long cache + edge CORS.
  dynamic "ordered_cache_behavior" {
    for_each = local.cached_path_patterns

    content {
      path_pattern     = ordered_cache_behavior.value
      target_origin_id = "honua-api-gateway"

      allowed_methods = ["GET", "HEAD", "OPTIONS"]
      cached_methods  = ["GET", "HEAD"]

      cache_policy_id            = aws_cloudfront_cache_policy.tiles.id
      origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
      response_headers_policy_id = aws_cloudfront_response_headers_policy.demo_cors.id

      viewer_protocol_policy = "redirect-to-https"
      compress               = true
    }
  }

  # Everything else (queries, OData, admin, healthz) — pure pass-through.
  default_cache_behavior {
    target_origin_id = "honua-api-gateway"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id

    viewer_protocol_policy = "redirect-to-https"
    compress               = true
  }

  # Don't let transient origin errors (Lambda cold-start hiccups, db
  # restarts) stick in the tile cache for the default 5 minutes.
  dynamic "custom_error_response" {
    for_each = [500, 502, 503, 504]

    content {
      error_code            = custom_error_response.value
      error_caching_min_ttl = 10
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.demo_cloudfront.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# IPv6 alias — CloudFront serves AAAA; API Gateway regional endpoints do not,
# so this record only exists once DNS points at the distribution. The A
# record lives in main.tf (aws_route53_record.demo) and follows the same
# route_demo_dns_to_cloudfront switch.
# ---------------------------------------------------------------------------

resource "aws_route53_record" "demo_aaaa" {
  count = var.route_demo_dns_to_cloudfront ? 1 : 0

  name    = "demo.honua.io"
  type    = "AAAA"
  zone_id = var.route53_zone_id

  alias {
    name                   = aws_cloudfront_distribution.demo.domain_name
    zone_id                = aws_cloudfront_distribution.demo.hosted_zone_id
    evaluate_target_health = false
  }
}
