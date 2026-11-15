locals {
  idp_client_readers = concat([local.service_role_arn], sort(tolist(var.idp_task_execution_role_arns)))
  idp_secret_controls = [
    {
      Sid       = "DenyBootstrapSecretMutation", Effect = "Deny"
      NotAction = ["secretsmanager:GetSecretValue"]
      Resource  = aws_secretsmanager_secret.idp_client.arn
    },
    {
      Sid       = "DenyUnapprovedIdpReaders", Effect = "Deny"
      Action    = ["secretsmanager:GetSecretValue"]
      Resource  = aws_secretsmanager_secret.idp_client.arn
      Condition = { ArnNotEquals = { "aws:PrincipalArn" = local.idp_client_readers } }
    }
  ]
}

resource "aws_secretsmanager_secret_policy" "idp_client" {
  secret_arn          = aws_secretsmanager_secret.idp_client.arn
  block_public_policy = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "secretsmanager:GetSecretValue"
      Principal = { AWS = aws_iam_role.cloudformation.arn }
      Resource  = aws_secretsmanager_secret.idp_client.arn
    }]
  })
}
