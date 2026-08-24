locals {
  oidc_hostpath = trimprefix(var.oidc_provider_url, "https://")

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_hostpath}:aud" = var.oidc_audience
          "${local.oidc_hostpath}:sub" = var.oidc_subject
        }
      }
    }]
  })

  backend_access_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StateObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:DeleteObject",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Resource = "${var.state_bucket_arn}/*"
      },
      {
        Sid    = "StateBucketDiscovery"
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning",
          "s3:ListBucket"
        ]
        Resource = var.state_bucket_arn
      },
      {
        Sid    = "StateLockAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:PutItem"
        ]
        Resource = var.state_lock_table_arn
      }
    ]
  })

  workload_identity_contract = {
    schema_version       = "v1"
    kind                 = "aws-sts-web-identity"
    role_name            = aws_iam_role.backend_access.name
    role_arn             = aws_iam_role.backend_access.arn
    issuer               = var.oidc_provider_url
    subject              = var.oidc_subject
    audience             = var.oidc_audience
    max_session_duration = var.max_session_duration
    backend = {
      state_bucket_arn = var.state_bucket_arn
      lock_table_arn   = var.state_lock_table_arn
    }
    permissions_purpose = "terraform-state-and-lock-only"
    credentials         = "short-lived-sts-only"
  }
}

resource "aws_iam_role" "backend_access" {
  name                 = var.role_name
  assume_role_policy   = local.assume_role_policy
  max_session_duration = var.max_session_duration
  tags                 = var.tags
}

resource "aws_iam_role_policy" "backend_access" {
  name   = "${var.role_name}-state-access"
  role   = aws_iam_role.backend_access.id
  policy = local.backend_access_policy
}
