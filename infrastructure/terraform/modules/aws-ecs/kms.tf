resource "random_password" "db" {
  count            = var.db_password == null && !local.db_use_existing ? 1 : 0
  length           = 32
  special          = true
  override_special = "#%*()-_=+[]{}:?."

  lifecycle {
    ignore_changes = [length, special, override_special]
  }
}

resource "random_password" "connection_encryption_master_key" {
  count            = var.connection_encryption_master_key == null ? 1 : 0
  length           = 32
  special          = true
  override_special = "#%*()-_=+[]{}:?."

  lifecycle {
    ignore_changes = [length, special, override_special]
  }
}

resource "random_password" "redis_auth" {
  count            = local.redis_create && var.redis_auth_token == "" ? 1 : 0
  length           = 32
  special          = true
  override_special = "!&#$^<>-"

  lifecycle {
    ignore_changes = [length, special, override_special]
  }
}

resource "random_id" "alb_logs_suffix" {
  byte_length = 4
}

resource "random_id" "app_storage_suffix" {
  count       = var.app_storage_enabled && trimspace(var.app_storage_bucket_name) == "" ? 1 : 0
  byte_length = 4
}

data "aws_iam_policy_document" "kms" {
  #checkov:skip=CKV_AWS_111: Root access is required for KMS administration.
  #checkov:skip=CKV_AWS_356: Root access is required for KMS administration.
  #checkov:skip=CKV_AWS_109: Root access is required for KMS administration.
  statement {
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowCloudWatchLogsUse"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.id}.amazonaws.com"]
    }
  }

  statement {
    sid       = "AllowSecretsManagerUse"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["secretsmanager.${data.aws_region.current.id}.amazonaws.com"]
    }
  }

  statement {
    sid       = "AllowElastiCacheUse"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant", "kms:RetireGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ViaService"
      values = [
        "elasticache.${data.aws_region.current.id}.amazonaws.com",
        "dax.${data.aws_region.current.id}.amazonaws.com"
      ]
    }
  }

  statement {
    sid       = "AllowEcsTaskExecutionDecrypt"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.task_execution.arn]
    }
  }
}

resource "aws_kms_key" "honua" {
  count                   = var.kms_key_arn == "" ? 1 : 0
  description             = "Honua infrastructure key"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms.json
  tags                    = local.tags
}

resource "aws_kms_alias" "honua" {
  count         = var.kms_key_arn == "" ? 1 : 0
  name          = "alias/${local.name}-honua"
  target_key_id = aws_kms_key.honua[0].key_id
}
