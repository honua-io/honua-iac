variable "cdn" {
  description = "CloudFront distribution on domain_name in front of the load balancer; it is the deployment's shared cache. The viewer ACM certificate must be issued in us-east-1 and cover domain_name. access_logs names an existing bucket that accepts CloudFront standard-log delivery."
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
  validation {
    condition     = var.cdn == null ? true : can(regex("^arn:aws:acm:us-east-1:[0-9]{12}:certificate/", var.cdn.viewer_certificate_arn))
    error_message = "Use a us-east-1 ACM certificate for the CloudFront viewer certificate."
  }
  validation {
    condition     = var.cdn == null ? true : contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cdn.price_class)
    error_message = "cdn.price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

locals {
  cdn_enabled = var.cdn != null || var.static_console != null
  cdn = var.cdn != null ? var.cdn : (var.static_console == null ? null : {
    viewer_certificate_arn = var.static_console.viewer_certificate_arn
    web_acl_id             = var.static_console.web_acl_id
    price_class            = "PriceClass_100"
    access_logs            = null
  })

  cdn_one_year_seconds = 31536000

  # AWS-managed policies: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html
  cdn_managed_caching_disabled_policy_id   = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
  cdn_managed_all_viewer_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
  cdn_managed_security_headers_policy_id   = "67f7725c-6f97-4210-82d7-5512b31e9d03"

  # The credential carriers and representation headers honua-server publishes for
  # its CDN. A request that carries a credential never shares a cache entry with
  # an anonymous request.
  cdn_credential_headers = [
    "Authorization", "X-API-Key", "X-Esri-Authorization", "X-Honua-Embed-Key", "X-Honua-Token", "X-Honua-Tenant",
  ]
  cdn_credential_cookies = ["honua_admin_session", "honua_admin_login"]
  # Accept-Encoding is normalized by the policy's Gzip and Brotli switches instead.
  cdn_representation_headers = ["Origin", "Accept", "Accept-Language", "Prefer"]

  # CloudFront allows ten headers in a cache policy and the lists above use all
  # ten. A viewer-request function gives a request that carries any of these
  # remaining headers a cache key of its own, so it is never answered from, or
  # stored into, an entry another request can reach.
  cdn_cache_bypass_headers = concat(
    ["X-Honua-Job-Id", "X-Forwarded-Client-Cert"],
    local.canary_enabled ? [var.canary_header_name] : []
  )
  cdn_cache_bypass_marker_cookie = "honua_cache_bypass"
  cdn_cache_key_cookies          = concat(local.cdn_credential_cookies, [local.cdn_cache_bypass_marker_cookie])

  # The server answers these with private, no-store; keeping them off the cached
  # behavior means an origin mistake cannot make them storable.
  cdn_uncached_path_patterns = [
    "*/admin",
    "*/admin/*",
    "/sharing/rest/generateToken*",
    "/sharing/rest/oauth2/*",
    "/oauth/*",
    "/signin-oidc*",
    "/saml/*",
    "/scim/*",
    "/mcp*",
    "/hubs/*",
  ]

  # CloudFront caches these error statuses for ten seconds unless told otherwise.
  cdn_error_status_codes = [400, 403, 404, 405, 414, 416, 500, 501, 502, 503, 504]

  cdn_environment = local.cdn_enabled ? {
    SharedCache__CloudFront__DistributionId = aws_cloudfront_distribution.cdn[0].id
  } : {}
}

resource "aws_cloudfront_cache_policy" "api" {
  count   = local.cdn_enabled ? 1 : 0
  name    = "${local.name}-api"
  comment = "Origin Cache-Control alone decides what is stored; credentials are part of the cache key."

  min_ttl     = 0
  default_ttl = 0
  max_ttl     = local.cdn_one_year_seconds

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    headers_config {
      header_behavior = "whitelist"
      headers { items = concat(local.cdn_credential_headers, local.cdn_representation_headers) }
    }
    cookies_config {
      cookie_behavior = "whitelist"
      cookies { items = local.cdn_cache_key_cookies }
    }
    # Any query parameter can change the bytes on some route, and this includes
    # the token and key credential parameters in every spelling.
    query_strings_config { query_string_behavior = "all" }
  }
}

resource "aws_cloudfront_cache_policy" "console_assets" {
  count   = var.static_console == null ? 0 : 1
  name    = "${local.name}-console-assets"
  comment = "Console framework files are stored only for as long as their S3 Cache-Control metadata says."

  min_ttl     = 0
  default_ttl = 0
  max_ttl     = local.cdn_one_year_seconds

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    headers_config { header_behavior = "none" }
    cookies_config { cookie_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
  }
}

resource "aws_cloudfront_function" "cache_bypass_marker" {
  count   = local.cdn_enabled ? 1 : 0
  name    = "${local.name}-cache-bypass-marker"
  runtime = "cloudfront-js-2.0"
  publish = true
  code = replace(replace(file("${path.module}/scripts/cache-bypass-marker.js"),
    "__BYPASS_HEADERS__", jsonencode([for header in local.cdn_cache_bypass_headers : lower(header)])),
  "__MARKER_COOKIE__", local.cdn_cache_bypass_marker_cookie)
}

resource "aws_cloudfront_distribution" "cdn" {
  #checkov:skip=CKV2_AWS_32: Console CSP must be validated against the published WASM bundle; managed security headers are applied at the edge.
  #checkov:skip=CKV_AWS_305: Root belongs to the API; a default root object would rewrite API requests.
  #checkov:skip=CKV2_AWS_47: Optional customer-managed WAF rules are outside this preview stack.
  #checkov:skip=CKV_AWS_68: WAF is optional for a customer-owned preview; supply web_acl_id for production.
  #checkov:skip=CKV_AWS_86: Distribution access logging is an account-owner retention and privacy decision; set cdn.access_logs.
  #checkov:skip=CKV_AWS_310: Origin failover requires a second independently deployed region.
  #checkov:skip=CKV_AWS_374: Preview has no paid WAF subscription requirement.
  count               = local.cdn_enabled ? 1 : 0
  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  wait_for_deployment = true
  aliases             = [var.domain_name]
  web_acl_id          = local.cdn.web_acl_id
  price_class         = local.cdn.price_class

  dynamic "origin" {
    for_each = var.static_console == null ? [] : [1]
    content {
      origin_id                = "console"
      domain_name              = aws_s3_bucket.deployment["console"].bucket_regional_domain_name
      origin_path              = "/${var.static_console.bundle_version}"
      origin_access_control_id = aws_cloudfront_origin_access_control.console[0].id
    }
  }
  origin {
    origin_id   = "api"
    domain_name = aws_lb.this.dns_name
    custom_header {
      name  = "X-Honua-Origin"
      value = random_password.cloudfront_origin[0].result
    }
    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_read_timeout      = 60
      origin_keepalive_timeout = 55
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id         = "api"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = aws_cloudfront_cache_policy.api[0].id
    origin_request_policy_id = local.cdn_managed_all_viewer_request_policy_id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.cache_bypass_marker[0].arn
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = local.cdn_uncached_path_patterns
    content {
      path_pattern             = ordered_cache_behavior.value
      target_origin_id         = "api"
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
      cached_methods           = ["GET", "HEAD"]
      cache_policy_id          = local.cdn_managed_caching_disabled_policy_id
      origin_request_policy_id = local.cdn_managed_all_viewer_request_policy_id
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = var.static_console == null ? [] : ["/console/_framework/*"]
    content {
      path_pattern               = ordered_cache_behavior.value
      target_origin_id           = "console"
      viewer_protocol_policy     = "redirect-to-https"
      allowed_methods            = ["GET", "HEAD", "OPTIONS"]
      cached_methods             = ["GET", "HEAD"]
      compress                   = true
      cache_policy_id            = aws_cloudfront_cache_policy.console_assets[0].id
      response_headers_policy_id = local.cdn_managed_security_headers_policy_id
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = var.static_console == null ? [] : ["/console", "/console/*"]
    content {
      path_pattern               = ordered_cache_behavior.value
      target_origin_id           = "console"
      viewer_protocol_policy     = "redirect-to-https"
      allowed_methods            = ["GET", "HEAD", "OPTIONS"]
      cached_methods             = ["GET", "HEAD"]
      cache_policy_id            = local.cdn_managed_caching_disabled_policy_id
      response_headers_policy_id = local.cdn_managed_security_headers_policy_id
      function_association {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.console_router[0].arn
      }
    }
  }

  dynamic "custom_error_response" {
    for_each = local.cdn_error_status_codes
    content {
      error_code            = custom_error_response.value
      error_caching_min_ttl = 0
    }
  }

  dynamic "logging_config" {
    for_each = local.cdn.access_logs == null ? [] : [local.cdn.access_logs]
    content {
      bucket          = logging_config.value.bucket_domain_name
      prefix          = logging_config.value.prefix
      include_cookies = false
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }
  viewer_certificate {
    acm_certificate_arn      = local.cdn.viewer_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
  tags = local.tags
}

moved {
  from = aws_cloudfront_distribution.console
  to   = aws_cloudfront_distribution.cdn
}

resource "aws_route53_record" "service_alias_ipv6" {
  count   = local.create_domain_alias && local.cdn_enabled ? 1 : 0
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.cdn[0].domain_name
    zone_id                = aws_cloudfront_distribution.cdn[0].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_iam_role_policy" "cdn_invalidation" {
  count = local.cdn_enabled ? 1 : 0
  name  = "${local.name}-cdn-invalidation"
  role  = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
      Resource = [aws_cloudfront_distribution.cdn[0].arn]
    }]
  })
}

output "cdn" {
  description = "The distribution that fronts the deployment, or null without one."
  value = local.cdn_enabled ? {
    distribution_id     = aws_cloudfront_distribution.cdn[0].id
    distribution_arn    = aws_cloudfront_distribution.cdn[0].arn
    distribution_domain = aws_cloudfront_distribution.cdn[0].domain_name
    url                 = "https://${var.domain_name}"
  } : null
}
