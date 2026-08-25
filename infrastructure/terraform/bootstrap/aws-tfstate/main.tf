provider "aws" {
  region = var.aws_region
}

data "aws_partition" "current" {}

locals {
  tags = merge(var.tags, {
    ManagedBy   = "terraform"
    Purpose     = "honua-terraform-state"
    Stack       = var.stack_name
    Environment = var.environment
  })

  # One explicit object key per stack + environment. `state_key_scopes` extends
  # the bootstrap to serve several stacks out of one hardened bucket without
  # ever letting two stacks share a key; the primary scope stays addressable as
  # `state_key` so existing callers keep working.
  scopes = length(var.state_key_scopes) > 0 ? var.state_key_scopes : [{
    stack_name  = var.stack_name
    environment = var.environment
  }]

  state_keys = {
    for scope in local.scopes :
    "${scope.stack_name}/${scope.environment}" => "honua/${scope.stack_name}/${scope.environment}/terraform.tfstate"
  }

  state_key = "honua/${var.stack_name}/${var.environment}/terraform.tfstate"

  sse_algorithm = var.kms_key_arn == "" ? "AES256" : "aws:kms"

  create_lock_table = var.lock_mode == "dynamodb" || var.lock_mode == "both"
  use_lockfile      = var.lock_mode == "s3_native" || var.lock_mode == "both"

  state_object_arns = [
    for key in values(local.state_keys) : "${aws_s3_bucket.state.arn}/${key}"
  ]

  # S3 native locking writes a sibling `<key>.tflock` object. The backend access
  # policy must reach exactly those objects and nothing else in the bucket.
  lock_object_arns = local.use_lockfile ? [
    for key in values(local.state_keys) : "${aws_s3_bucket.state.arn}/${key}.tflock"
  ] : []

  lock_contract = local.use_lockfile ? {
    kind                  = var.lock_mode == "both" ? "s3-native-lockfile+dynamodb" : "s3-native-lockfile"
    lock_object_suffix    = ".tflock"
    table_name            = local.create_lock_table ? aws_dynamodb_table.lock[0].name : null
    table_arn             = local.create_lock_table ? aws_dynamodb_table.lock[0].arn : null
    min_terraform_version = "1.10.0"
    } : {
    kind                  = "dynamodb"
    lock_object_suffix    = null
    table_name            = aws_dynamodb_table.lock[0].name
    table_arn             = aws_dynamodb_table.lock[0].arn
    min_terraform_version = "1.5.0"
  }

  backend_contract = {
    schema_version = "v1"
    backend_kind   = "aws-s3"
    account_region = {
      region    = var.aws_region
      partition = data.aws_partition.current.partition
    }
    state = {
      bucket_name = aws_s3_bucket.state.bucket
      bucket_arn  = aws_s3_bucket.state.arn
      object_key  = local.state_key
      object_keys = local.state_keys
      key_scope   = "stack-and-environment"
    }
    locking = local.lock_contract
    encryption = {
      algorithm   = local.sse_algorithm
      kms_key_arn = var.kms_key_arn != "" ? var.kms_key_arn : null
    }
    access = {
      backend_access_policy_arn = var.create_backend_access_policy ? aws_iam_policy.backend_access[0].arn : null
      scope                     = "state-objects-and-lock-only"
    }
    protections = {
      versioning_enabled        = true
      point_in_time_recovery    = local.create_lock_table
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

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  lifecycle {
    prevent_destroy = true
  }

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  lifecycle {
    prevent_destroy = true
  }

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  lifecycle {
    prevent_destroy = true
  }

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  lifecycle {
    prevent_destroy = true
  }

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

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Locking primitive.
#
# The certified default is S3 native locking (`use_lockfile = true`), which
# needs Terraform >= 1.10 and keeps the lock inside the same encrypted,
# versioned, public-access-blocked bucket as the state it guards. DynamoDB
# remains available for operators pinned below 1.10, and `both` exists only to
# make the migration between them a two-step, no-downtime change.
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "lock" {
  count = local.create_lock_table ? 1 : 0

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

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Least-privilege backend access policy.
#
# This is the ONLY grant a Terraform executor needs against the state
# substrate: the exact state objects for the configured scopes, their lock
# objects, prefix-scoped bucket listing, and (when locking on DynamoDB) the four
# item operations the backend uses. It deliberately grants no bucket
# administration, no access to other keys, and no ability to disable versioning,
# encryption, or the public-access block. Attach it to the deployment identity's
# BACKEND role -- never to the infrastructure deployment role.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "backend_access" {
  count = var.create_backend_access_policy ? 1 : 0

  statement {
    sid    = "StateObjectAccess"
    effect = "Allow"
    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
    ]
    resources = concat(local.state_object_arns, local.lock_object_arns)
  }

  statement {
    sid    = "StateBucketDiscovery"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning",
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.state.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [for key in values(local.state_keys) : key]
    }
  }

  dynamic "statement" {
    for_each = local.create_lock_table ? [1] : []

    content {
      sid    = "StateLockTableAccess"
      effect = "Allow"
      actions = [
        "dynamodb:DeleteItem",
        "dynamodb:DescribeTable",
        "dynamodb:GetItem",
        "dynamodb:PutItem",
      ]
      resources = [aws_dynamodb_table.lock[0].arn]
    }
  }

  dynamic "statement" {
    for_each = var.kms_key_arn == "" ? [] : [var.kms_key_arn]

    content {
      sid    = "StateKmsAccess"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:Encrypt",
        "kms:GenerateDataKey",
      ]
      resources = [statement.value]
    }
  }

  # Even if a wider grant is attached elsewhere, this identity can never weaken
  # the protections that make the bucket a trustworthy state store.
  statement {
    sid    = "DenyStateSubstrateAdministration"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketAcl",
      "s3:PutBucketPolicy",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
    ]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
  }
}

resource "aws_iam_policy" "backend_access" {
  count = var.create_backend_access_policy ? 1 : 0

  name        = "${var.bucket_name}-backend-access"
  description = "Least-privilege Terraform backend access for the Honua state substrate."
  policy      = data.aws_iam_policy_document.backend_access[0].json
  tags        = local.tags
}
