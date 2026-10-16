# ECS retrieves only the reviewed version for this attempt. The running task
# retains its existing queue-only AWS role; it cannot fetch arbitrary secrets.
resource "aws_iam_role_policy" "mcp_configuration" {
  count = var.mcp_configuration == null ? 0 : 1
  role  = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.mcp_configuration.secret_arn
        Condition = {
          StringEquals = {
            "secretsmanager:VersionId"              = var.mcp_configuration.version_id
            "aws:ResourceTag/honua-agent-attempt"   = var.attempt_id
            "aws:ResourceTag/honua-agent-candidate" = var.candidate_digest
          }
          DateLessThan = { "aws:CurrentTime" = local.expires_at }
        }
      }
      ], var.mcp_configuration.kms_key_arn == null ? [] : [
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.mcp_configuration.kms_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService"                        = "secretsmanager.${var.region}.amazonaws.com"
            "kms:EncryptionContext:SecretARN"       = var.mcp_configuration.secret_arn
            "kms:EncryptionContext:SecretVersionId" = var.mcp_configuration.version_id
          }
          DateLessThan = { "aws:CurrentTime" = local.expires_at }
        }
      }
    ])
  })
}
