variable "static_console" {
  description = "Static Console at /console/ on domain_name; viewer ACM certificate must be issued in us-east-1 and cover the same hostname as the regional ALB certificate. Upload the verified bundle separately."
  type = object({
    viewer_certificate_arn = string
    bundle_version         = string
    web_acl_id             = optional(string)
  })
  default = null
  validation {
    condition = var.static_console == null ? true : (
      can(regex("^arn:aws:acm:us-east-1:[0-9]{12}:certificate/", var.static_console.viewer_certificate_arn)) &&
      can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$", var.static_console.bundle_version))
    )
    error_message = "Use a us-east-1 ACM certificate and a bundle_version containing only letters, digits, dot, underscore or hyphen."
  }
}

variable "file_storage_aws_s3_create_bucket" {
  description = "Create a private versioned bucket for shared file storage. Requires file_storage_provider=AwsS3 and no supplied bucket name."
  type        = bool
  default     = false
}

locals {
  deployment_bucket_names = merge(
    var.static_console == null ? {} : { console = "console" },
    var.file_storage_aws_s3_create_bucket ? { files = "files" } : {}
  )
  file_storage_bucket_name = var.file_storage_aws_s3_create_bucket ? aws_s3_bucket.deployment["files"].id : var.file_storage_aws_s3_bucket_name
}

resource "terraform_data" "static_console_validation" {
  lifecycle {
    precondition {
      condition = var.static_console == null || (
        local.use_https && var.domain_name != "" && !local.canary_enabled && var.console == null &&
        !var.alb_enable_http_redirect && length(var.allow_http_ingress_cidrs) == 0 && length(var.allow_public_ingress_cidrs) == 0
      )
      error_message = "Static Console requires a custom HTTPS domain, no canary or legacy Console, no public ingress override, and HTTP redirect disabled."
    }
    precondition {
      condition     = !var.file_storage_aws_s3_create_bucket || (var.file_storage_provider == "AwsS3" && var.file_storage_aws_s3_bucket_name == "")
      error_message = "Managed file storage requires AwsS3 with no existing bucket name."
    }
  }
}

resource "aws_s3_bucket" "deployment" {
  #checkov:skip=CKV_AWS_145: SSE-S3 encrypts both buckets; Console OAC needs no customer KMS grants.
  #checkov:skip=CKV_AWS_144: Cross-region replication is an operator disaster-recovery choice.
  #checkov:skip=CKV2_AWS_62: Object notifications are not needed for static assets or server-managed file storage.
  #checkov:skip=CKV_AWS_18: Access auditing uses CloudTrail data events configured by the account owner.
  #checkov:skip=CKV2_AWS_61: Version deletion is deliberately manual to preserve rollback artifacts and customer data.
  for_each      = local.deployment_bucket_names
  bucket_prefix = "honua-${each.key}-"
  force_destroy = false
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "deployment" {
  for_each                = local.deployment_bucket_names
  bucket                  = aws_s3_bucket.deployment[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "deployment" {
  for_each = local.deployment_bucket_names
  bucket   = aws_s3_bucket.deployment[each.key].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "deployment" {
  #checkov:skip=CKV2_AWS_67: SSE-S3 supports CloudFront OAC without customer-key access grants.
  for_each = local.deployment_bucket_names
  bucket   = aws_s3_bucket.deployment[each.key].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_ownership_controls" "deployment" {
  for_each = local.deployment_bucket_names
  bucket   = aws_s3_bucket.deployment[each.key].id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_policy" "deployment" {
  for_each = local.deployment_bucket_names
  bucket   = aws_s3_bucket.deployment[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.deployment[each.key].arn, "${aws_s3_bucket.deployment[each.key].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
      ], each.key == "console" ? [{
        Sid       = "CloudFrontReadOnly"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.deployment[each.key].arn}/*"
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.console[0].arn } }
    }] : [])
  })
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  count = var.static_console == null ? 0 : 1
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "random_password" "cloudfront_origin" {
  count   = var.static_console == null ? 0 : 1
  length  = 48
  special = false
}

resource "aws_cloudfront_origin_access_control" "console" {
  count                             = var.static_console == null ? 0 : 1
  name                              = "${local.name}-console"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "console_router" {
  count   = var.static_console == null ? 0 : 1
  name    = "${local.name}-console-router"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = file("${path.module}/scripts/console-router.js")
}

resource "aws_cloudfront_distribution" "console" {
  #checkov:skip=CKV2_AWS_32: Console CSP must be validated against the published WASM bundle; managed security headers are applied at the edge.
  #checkov:skip=CKV_AWS_305: Root belongs to the API; a default root object would rewrite API requests.
  #checkov:skip=CKV2_AWS_47: Optional customer-managed WAF rules are outside this preview stack.
  #checkov:skip=CKV_AWS_68: WAF is optional for a customer-owned preview; supply web_acl_id for production.
  #checkov:skip=CKV_AWS_86: Distribution access logging is an account-owner retention and privacy decision.
  #checkov:skip=CKV_AWS_310: Origin failover requires a second independently deployed region.
  #checkov:skip=CKV_AWS_374: Preview has no paid WAF subscription requirement.
  count               = var.static_console == null ? 0 : 1
  enabled             = true
  is_ipv6_enabled     = true
  wait_for_deployment = true
  aliases             = [var.domain_name]
  web_acl_id          = var.static_console.web_acl_id
  price_class         = "PriceClass_100"

  origin {
    origin_id                = "console"
    domain_name              = aws_s3_bucket.deployment["console"].bucket_regional_domain_name
    origin_path              = "/${var.static_console.bundle_version}"
    origin_access_control_id = aws_cloudfront_origin_access_control.console[0].id
  }
  origin {
    origin_id   = "api"
    domain_name = aws_lb.this.dns_name
    custom_header {
      name  = "X-Honua-Origin"
      value = random_password.cloudfront_origin[0].result
    }
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }
  default_cache_behavior {
    target_origin_id         = "api"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
  }
  dynamic "ordered_cache_behavior" {
    for_each = ["/console", "/console/*"]
    content {
      path_pattern               = ordered_cache_behavior.value
      target_origin_id           = "console"
      viewer_protocol_policy     = "redirect-to-https"
      allowed_methods            = ["GET", "HEAD", "OPTIONS"]
      cached_methods             = ["GET", "HEAD"]
      cache_policy_id            = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
      response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03"
      function_association {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.console_router[0].arn
      }
    }
  }
  restrictions {
    geo_restriction { restriction_type = "none" }
  }
  viewer_certificate {
    acm_certificate_arn      = var.static_console.viewer_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
  tags = local.tags
}

resource "aws_route53_record" "console" {
  count   = var.static_console != null && var.domain_alias_record_enabled && var.route53_zone_id != "" ? 1 : 0
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.console[0].domain_name
    zone_id                = aws_cloudfront_distribution.console[0].hosted_zone_id
    evaluate_target_health = false
  }
}

output "static_console" {
  description = "Bundle upload target and same-origin distribution. Upload <version>/console/* before directing customer traffic here."
  value = var.static_console == null ? null : {
    bucket              = aws_s3_bucket.deployment["console"].id
    bundle_prefix       = "${var.static_console.bundle_version}/console/"
    distribution_id     = aws_cloudfront_distribution.console[0].id
    distribution_domain = aws_cloudfront_distribution.console[0].domain_name
    url                 = "https://${var.domain_name}/console/"
  }
}

output "file_storage_bucket" {
  value       = local.file_storage_bucket_name
  description = "Shared file storage bucket; private and versioned when managed by this module."
}
