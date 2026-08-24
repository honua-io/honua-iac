provider "aws" {
  region = var.aws_region
}

locals {
  tags = merge(var.tags, {
    ManagedBy   = "terraform"
    Purpose     = "honua-terraform-state"
    Stack       = var.stack_name
    Environment = var.environment
  })

  state_key     = "honua/${var.stack_name}/${var.environment}/terraform.tfstate"
  sse_algorithm = var.kms_key_arn == "" ? "AES256" : "aws:kms"

  backend_contract = {
    schema_version = "v1"
    backend_kind   = "aws-s3"
    account_region = {
      region = var.aws_region
    }
    state = {
      bucket_name = aws_s3_bucket.state.bucket
      bucket_arn  = aws_s3_bucket.state.arn
      object_key  = local.state_key
      key_scope   = "stack-and-environment"
    }
    locking = {
      kind       = "dynamodb"
      table_name = aws_dynamodb_table.lock.name
      table_arn  = aws_dynamodb_table.lock.arn
    }
    encryption = {
      algorithm   = local.sse_algorithm
      kms_key_arn = var.kms_key_arn != "" ? var.kms_key_arn : null
    }
    protections = {
      versioning_enabled        = true
      point_in_time_recovery    = true
      public_access_blocked     = true
      insecure_transport_denied = true
      force_destroy             = false
    }
  }
}

resource "aws_s3_bucket" "state" {
  bucket        = var.bucket_name
  force_destroy = false
  tags          = local.tags
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.sse_algorithm
      kms_master_key_id = var.kms_key_arn != "" ? var.kms_key_arn : null
    }
  }
}

data "aws_iam_policy_document" "state_transport" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state_transport" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_transport.json
}

resource "aws_dynamodb_table" "lock" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = local.tags
}
