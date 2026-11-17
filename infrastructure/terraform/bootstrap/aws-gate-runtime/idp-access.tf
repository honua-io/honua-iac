locals {
  # CloudFormation names the template's ExecutionRole "<stack>-ExecutionRole-<suffix>". Only the
  # CloudFormation service role creates honua-gate-* roles, always under the workload boundary,
  # so the pattern admits gate task execution roles without a per-install apply.
  idp_execution_role_pattern = "arn:aws:iam::${var.member_account_id}:role/honua-gate-*-ExecutionRole-*"
  idp_client_readers         = concat([local.service_role_arn, local.idp_execution_role_pattern], sort(tolist(var.idp_task_execution_role_arns)))
  # Statement labels are omitted to keep the workload boundary within its size quota. The admin
  # secret is in local.protected_controls (deny all), which both gate policies already carry.
  idp_secret_controls = [
    {
      Effect    = "Deny"
      NotAction = ["secretsmanager:GetSecretValue"]
      Resource  = aws_secretsmanager_secret.idp_client.arn
    },
    {
      Effect    = "Deny"
      Action    = ["secretsmanager:GetSecretValue"]
      Resource  = aws_secretsmanager_secret.idp_client.arn
      Condition = { ArnNotLike = { "aws:PrincipalArn" = local.idp_client_readers } }
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
