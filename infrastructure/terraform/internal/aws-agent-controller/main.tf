provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
}

locals {
  candidate_hex        = trimprefix(var.candidate_digest, "sha256:")
  name                 = "honua-agent-${substr(local.candidate_hex, 0, 24)}"
  bucket_name          = "${local.name}-${var.account_id}"
  bucket_arn           = "arn:aws:s3:::${local.bucket_name}"
  state_prefix         = "agent-e2e/${local.candidate_hex}/"
  evidence_prefix      = "evidence/${local.candidate_hex}/"
  controller_role_name = element(reverse(split("/", var.controller_role_arn)), 0)
  runtime_principals   = setunion(toset([var.controller_role_arn]), toset([for controller in var.installed_runtime_controllers : controller.role_arn]))
  state_principals     = sort(tolist(setunion(var.state_admin_role_arns, local.runtime_principals)))
  tags = {
    ManagedBy               = "terraform"
    Owner                   = "honua-agent-e2e"
    "honua-agent-candidate" = var.candidate_digest
    "honua-agent-retained"  = "accounting-history"
  }
}

resource "aws_s3_bucket" "state" {
  bucket        = local.bucket_name
  force_destroy = false
  tags          = local.tags
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = alltrue([for arn in setunion(toset(local.state_principals), var.claim_writer_role_arns) : startswith(arn, "arn:aws:iam::${var.account_id}:role/")]) && length(setintersection(var.state_admin_role_arns, local.runtime_principals)) == 0 && !contains([for controller in var.installed_runtime_controllers : controller.role_arn], var.controller_role_arn) && alltrue([for controller in var.installed_runtime_controllers : contains([for slot in var.installed_worker_slots : slot.runtime_id], controller.runtime_id)]) && length(setintersection(var.claim_writer_role_arns, toset(local.state_principals))) == 0 && length(setsubtract(local.installed_lifecycle_roles, var.claim_writer_role_arns)) == 0
      error_message = "All state roles must belong to the reviewed account; runtime and administration roles must be separate."
    }
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_policy" "state" {
  bucket     = aws_s3_bucket.state.id
  depends_on = [aws_s3_bucket_public_access_block.state]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Sid      = "RequireTLS", Effect = "Deny", Principal = "*", Action = "s3:*",
        Resource = [local.bucket_arn, "${local.bucket_arn}/*"],
      Condition = { Bool = { "aws:SecureTransport" = "false" } } },
      { Sid      = "OnlyControllerAndStateAdministrators", Effect = "Deny", Principal = "*", Action = "s3:*",
        Resource = [local.bucket_arn, "${local.bucket_arn}/*"],
      Condition = { ArnNotEquals = { "aws:PrincipalArn" = local.state_principals } } },
      # Conditional writes protect the permanent initialization marker as well
      # as snapshots and evidence. Multipart/CopyObject is intentionally denied.
      # "*" is the literal If-None-Match value, not a StringLike wildcard.
      { Sid      = "RequireCreateOnlyObjects", Effect = "Deny", Principal = "*", Action = "s3:PutObject",
        Resource = "${local.bucket_arn}/*",
      Condition = { StringNotEquals = { "s3:if-none-match" = "*" } } },
      { Sid       = "RuntimeCannotEraseOrReconfigureHistory", Effect = "Deny", Principal = "*",
        NotAction = ["s3:GetBucketVersioning", "s3:ListBucketVersions", "s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"],
        Resource  = [local.bucket_arn, "${local.bucket_arn}/*"],
      Condition = { ArnEquals = { "aws:PrincipalArn" = sort(tolist(local.runtime_principals)) } } }
      ], length(var.installed_runtime_controllers) == 0 ? [] : [{
        Sid       = "InstalledRuntimeCannotForgeProvisioningOriginals", Effect = "Deny", Principal = "*", Action = "s3:PutObject",
        Resource  = ["${local.bucket_arn}/${local.state_prefix}initialization.json", "${local.bucket_arn}/${local.state_prefix}installed-controllers/*", "${local.bucket_arn}/${local.state_prefix}installed-workers/*"],
        Condition = { ArnEquals = { "aws:PrincipalArn" = [for controller in var.installed_runtime_controllers : controller.role_arn] } }
    }])
  })
}

# No TTL or expiration rule: a missing head or old launch claim never grants
# a new allowance or lets a replacement task replay an interrupted attempt.
resource "aws_dynamodb_table" "history" {
  for_each                    = toset(["state", "claims"])
  name                        = "${local.name}-${each.key}"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "candidateKey"
  deletion_protection_enabled = true
  attribute {
    name = "candidateKey"
    type = "S"
  }
  point_in_time_recovery { enabled = true }
  server_side_encryption { enabled = true }
  tags = local.tags
  lifecycle { prevent_destroy = true }
}

resource "aws_dynamodb_resource_policy" "state" {
  resource_arn = aws_dynamodb_table.history["state"].arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid      = "OnlyControllerAndStateAdministrators", Effect = "Deny", Principal = "*", Action = "dynamodb:*",
        Resource = aws_dynamodb_table.history["state"].arn,
      Condition = { ArnNotEquals = { "aws:PrincipalArn" = local.state_principals } } },
      { Sid       = "RuntimeCanOnlyUseFencedStateOperations", Effect = "Deny", Principal = "*",
        NotAction = concat(["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:DescribeTable"], local.has_installed_slots ? ["dynamodb:ConditionCheckItem"] : []),
        Resource  = aws_dynamodb_table.history["state"].arn,
      Condition = { ArnEquals = { "aws:PrincipalArn" = sort(tolist(local.runtime_principals)) } } }
    ]
  })
}

resource "aws_dynamodb_resource_policy" "claims" {
  resource_arn = aws_dynamodb_table.history["claims"].arn
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = jsondecode(local.has_installed_slots ? jsonencode(local.installed_claim_statements) : jsonencode(local.static_claim_statements))
  })
}

resource "aws_iam_role_policy" "controller_state" {
  name       = "${local.name}-state"
  role       = local.controller_role_name
  depends_on = [aws_s3_bucket_versioning.state, aws_s3_bucket_policy.state, aws_dynamodb_resource_policy.state]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Sid = "ObserveVersioning", Effect = "Allow", Action = "s3:GetBucketVersioning", Resource = local.bucket_arn },
      { Sid = "InspectRetainedCandidateHistory", Effect = "Allow", Action = "s3:ListBucketVersions", Resource = local.bucket_arn,
      Condition = { StringLike = { "s3:prefix" = ["${local.state_prefix}*", "${local.evidence_prefix}*"] } } },
      { Sid = "ReadExactEvidenceVersions", Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion"],
      Resource = ["${local.bucket_arn}/${local.state_prefix}*", "${local.bucket_arn}/${local.evidence_prefix}*"] },
      { Sid      = "AppendEvidence", Effect = "Allow", Action = "s3:PutObject",
        Resource = ["${local.bucket_arn}/${local.state_prefix}*", "${local.bucket_arn}/${local.evidence_prefix}*"],
      Condition = { StringEquals = { "s3:if-none-match" = "*" } } },
      { Sid      = "FencedCandidateHead", Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:UpdateItem"],
        Resource = aws_dynamodb_table.history["state"].arn,
      Condition = { "ForAllValues:StringEquals" = { "dynamodb:LeadingKeys" = [var.candidate_digest] } } },
      { Sid = "ObserveStateTable", Effect = "Allow", Action = "dynamodb:DescribeTable", Resource = aws_dynamodb_table.history["state"].arn }
      ], local.has_installed_slots ? [{
        Sid = "FenceInstalledRetirement", Effect = "Allow", Action = "dynamodb:ConditionCheckItem", Resource = aws_dynamodb_table.history["state"].arn,
        Condition = { "ForAllValues:StringEquals" = { "dynamodb:LeadingKeys" = [var.candidate_digest] },
        StringEquals = { "dynamodb:EnclosingOperation" = "TransactWriteItems" } }
    }] : [])
  })
}

# Preserve the original controller policy/address. Optional pollers receive the
# same candidate head fencing and append-only object policy, without admin status.
resource "aws_iam_role_policy" "installed_controller_state" {
  for_each = { for controller in var.installed_runtime_controllers : controller.role_arn => controller }
  name     = "${local.name}-state"
  role     = element(reverse(split("/", each.key)), 0)
  policy   = aws_iam_role_policy.controller_state.policy
}
