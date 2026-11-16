# Launch Stack templates exceed the 51,200-byte inline TemplateBody limit, so
# the lane uploads them here and passes an S3 TemplateURL. The name matches the
# honua-gate-* bucket namespace the service role may manage; the bucket policy
# fences that role to object reads and lets workload roles read only Console bundles.
# SSE-S3 (Amazon S3 managed keys), not the aws/s3 KMS key: the lane boundary
# allows no kms:*, and shared-account mode denies kms:Decrypt on keys no gate
# stack owns.
locals {
  template_bucket     = "honua-gate-templates-${var.member_account_id}"
  template_bucket_arn = "arn:aws:s3:::${local.template_bucket}"
  template_objects    = "${local.template_bucket_arn}/templates/*"
  console_objects     = "${local.template_bucket_arn}/templates/*/console.zip"
}
resource "aws_s3_bucket" "templates" {
  bucket = local.template_bucket
}
resource "aws_s3_bucket_ownership_controls" "templates" {
  bucket = aws_s3_bucket.templates.id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_public_access_block" "templates" {
  bucket                  = aws_s3_bucket.templates.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_versioning" "templates" {
  bucket = aws_s3_bucket.templates.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "templates" {
  bucket = aws_s3_bucket.templates.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "templates" {
  bucket     = aws_s3_bucket.templates.id
  depends_on = [aws_s3_bucket_versioning.templates]
  rule {
    id     = "expire-templates"
    status = "Enabled"
    filter {}
    expiration { days = 14 }
    noncurrent_version_expiration { noncurrent_days = 14 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}
resource "aws_s3_bucket_policy" "templates" {
  bucket     = aws_s3_bucket.templates.id
  depends_on = [aws_s3_bucket_public_access_block.templates]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TlsOnly", Effect = "Deny", Principal = "*", Action = "s3:*"
      Resource  = [local.template_bucket_arn, "${local.template_bucket_arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }, {
      Sid       = "OnlyCloudFormationReads", Effect = "Deny", Principal = "*", NotAction = "s3:GetObject"
      Resource  = [local.template_bucket_arn, "${local.template_bucket_arn}/*"]
      Condition = { ArnEquals = { "aws:PrincipalArn" = local.service_role_arn } }
      }, {
      Sid       = "NoWorkloadAccess", Effect = "Deny", Principal = "*", NotAction = "s3:GetObject"
      Resource  = [local.template_bucket_arn, "${local.template_bucket_arn}/*"]
      Condition = { ArnLike = { "aws:PrincipalArn" = local.workload_roles } }
      }, {
      # A gate stack's Console installer reads the published bundle with its own role when the
      # anonymous read is refused; it gets that archive and nothing else in the bucket.
      Sid         = "WorkloadsReadOnlyConsoleBundles", Effect = "Deny", Principal = "*", Action = "s3:GetObject"
      NotResource = [local.console_objects]
      Condition   = { ArnLike = { "aws:PrincipalArn" = local.workload_roles } }
    }]
  })
}
output "template_bucket_name" {
  value       = aws_s3_bucket.templates.bucket
  description = "Upload Launch Stack templates under templates/ and pass the object URL as TemplateURL; objects expire after 14 days."
}
