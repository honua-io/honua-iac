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

variable "file_storage_aws_s3_force_destroy" {
  description = "Let destroy delete the created file storage bucket together with every object and version in it. For disposable stacks only; the default refuses to delete a bucket that holds data."
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
      condition = !local.cdn_enabled || (
        local.use_https && var.domain_name != "" && var.console == null &&
        !var.alb_enable_http_redirect && length(var.allow_http_ingress_cidrs) == 0 && length(var.allow_public_ingress_cidrs) == 0
      )
      error_message = "CloudFront (cdn or static_console) requires a custom HTTPS domain, no legacy Console, no public ingress override, and HTTP redirect disabled."
    }
    precondition {
      condition     = var.cdn == null || var.static_console == null ? true : var.cdn.viewer_certificate_arn == var.static_console.viewer_certificate_arn
      error_message = "cdn and static_console share one distribution: give both the same viewer_certificate_arn."
    }
    precondition {
      condition     = !local.cdn_enabled || !local.canary_enabled || var.canary_listener_rule_priority < 50000
      error_message = "With CloudFront and a canary, canary_listener_rule_priority must be below 50000 so the rule that admits CloudFront can follow it."
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
  force_destroy = each.key == "files" && var.file_storage_aws_s3_force_destroy
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

data "aws_iam_policy_document" "deployment_bucket" {
  for_each = local.deployment_bucket_names
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.deployment[each.key].arn, "${aws_s3_bucket.deployment[each.key].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
  dynamic "statement" {
    for_each = each.key == "console" ? [1] : []
    content {
      sid       = "CloudFrontReadOnly"
      effect    = "Allow"
      actions   = ["s3:GetObject"]
      resources = ["${aws_s3_bucket.deployment[each.key].arn}/*"]
      principals {
        type        = "Service"
        identifiers = ["cloudfront.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "AWS:SourceArn"
        values   = [aws_cloudfront_distribution.cdn[0].arn]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "deployment" {
  for_each = local.deployment_bucket_names
  bucket   = aws_s3_bucket.deployment[each.key].id
  policy   = data.aws_iam_policy_document.deployment_bucket[each.key].json
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  count = local.cdn_enabled ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "random_password" "cloudfront_origin" {
  count   = local.cdn_enabled ? 1 : 0
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

output "static_console" {
  description = "Bundle upload target and same-origin distribution. Upload <version>/console/* before directing customer traffic here."
  value = var.static_console == null ? null : {
    bucket              = aws_s3_bucket.deployment["console"].id
    bundle_prefix       = "${var.static_console.bundle_version}/console/"
    distribution_id     = aws_cloudfront_distribution.cdn[0].id
    distribution_domain = aws_cloudfront_distribution.cdn[0].domain_name
    url                 = "https://${var.domain_name}/console/"
  }
}

output "file_storage_bucket" {
  value       = local.file_storage_bucket_name
  description = "Shared file storage bucket; private and versioned when managed by this module."
}
