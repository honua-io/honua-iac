locals {
  # CloudFormation names the template's ExecutionRole <stack>-ExecutionRole-<suffix>. Only HonuaGateCloudFormation
  # creates honua-gate-* roles, always under the workload boundary, so the pattern admits no principal outside
  # gate stacks. BatchExecutionRole and TaskRole names lack the "-ExecutionRole-" segment and stay denied.
  # The boundary governs only those stack-created roles, so the account segment is a wildcard to save quota.
  idp_execution_role_pattern = "arn:aws:iam::*:role/honua-gate-*-ExecutionRole-*"
  # Exact registrations already covered by the pattern are dropped so old tfvars cannot push the boundary past quota.
  idp_boundary_readers = concat([local.idp_execution_role_pattern], [
    for arn in sort(tolist(var.idp_task_execution_role_arns)) : arn if !can(regex("^arn:aws:iam::[0-9]{12}:role/honua-gate-.*-ExecutionRole-.*$", arn))
  ])
  # Statement labels are omitted to keep the workload boundary within its size quota.
  # Each policy names only the principals it governs: the CloudFormation role carries no boundary, and the
  # workload boundary applies only to stack-created roles.
  idp_secret_fences = [
    {
      Effect    = "Deny"
      NotAction = ["secretsmanager:GetSecretValue"]
      Resource  = [aws_secretsmanager_secret.idp_client.arn, aws_secretsmanager_secret.idp_admin.arn]
    },
    {
      Effect   = "Deny"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.idp_admin.arn
    }
  ]
  idp_client_read_fence = { Effect = "Deny", Action = ["secretsmanager:GetSecretValue"], Resource = aws_secretsmanager_secret.idp_client.arn }
  idp_secret_controls = concat(local.idp_secret_fences, [merge(local.idp_client_read_fence, {
    Condition = { ArnNotEquals = { "aws:PrincipalArn" = [local.service_role_arn] } }
  })])
  idp_boundary_secret_controls = concat(local.idp_secret_fences, [merge(local.idp_client_read_fence, {
    Condition = { ArnNotLike = { "aws:PrincipalArn" = local.idp_boundary_readers } }
  })])
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
