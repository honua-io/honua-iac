# Lane-invoked callback sync for the gate IdP client. The function lives in the protected
# honua-gate-reaper* namespace, so neither gate stacks nor the CloudFormation role can change it,
# and its role is outside honua-gate-*, so stacks cannot alter its permissions.
data "archive_file" "idp_callbacks" {
  type        = "zip"
  source_file = "${path.module}/idp-callbacks/handler.py"
  output_path = "${path.module}/.terraform/gate-idp-callbacks.zip"
}
resource "aws_iam_role" "idp_callbacks" {
  name = "HonuaGateCallbackSync"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}
resource "aws_cloudwatch_log_group" "idp_callbacks" {
  name              = "/aws/lambda/honua-gate-reaper-callbacks"
  retention_in_days = 14
}
resource "aws_iam_role_policy" "idp_callbacks" {
  name = "gate-idp-callbacks-only"
  role = aws_iam_role.idp_callbacks.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "cloudformation:ListStacks", Resource = "*" }, {
      Effect = "Allow", Action = "cloudformation:DescribeStacks", Resource = local.stack_arn
      }, {
      Effect   = "Allow", Action = ["cognito-idp:DescribeUserPoolClient", "cognito-idp:UpdateUserPoolClient"]
      Resource = aws_cognito_user_pool.gate.arn
      }, {
      Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.idp_callbacks.arn}:*"
    }]
  })
}
resource "aws_lambda_function" "idp_callbacks" {
  function_name                  = "honua-gate-reaper-callbacks"
  description                    = "Sync gate IdP callbacks with live gate stacks."
  role                           = aws_iam_role.idp_callbacks.arn
  runtime                        = "python3.13"
  handler                        = "handler.lambda_handler"
  filename                       = data.archive_file.idp_callbacks.output_path
  source_code_hash               = data.archive_file.idp_callbacks.output_base64sha256
  timeout                        = 60
  memory_size                    = 128
  reserved_concurrent_executions = 1
  environment {
    variables = {
      USER_POOL_ID     = aws_cognito_user_pool.gate.id
      CLIENT_ID        = aws_cognito_user_pool_client.gate.id
      STATIC_CALLBACKS = join(",", sort(tolist(var.idp_callback_urls)))
    }
  }
  depends_on = [aws_iam_role_policy.idp_callbacks, aws_cloudwatch_log_group.idp_callbacks]
}
output "idp_callback_sync_function" {
  value       = aws_lambda_function.idp_callbacks.function_name
  description = "Invoke after a gate stack completes to register its OidcCallbackUrl on the gate IdP client."
}
