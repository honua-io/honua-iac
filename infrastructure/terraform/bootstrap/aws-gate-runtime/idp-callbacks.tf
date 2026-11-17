# Registers each live gate stack's CloudFront callback on the gate IdP client, so a new
# install needs no Terraform apply. The name sits in the reserved honua-gate-reaper* namespace: the
# protected_controls deny that keeps templates and workloads from modifying the reaper covers this function
# and its log group too, without spending workload-boundary quota. Its role is outside honua-gate-*, which
# templates may create and modify.
locals {
  idp_callbacks_function = "honua-gate-reaper-idp-callbacks"
  idp_callbacks_arn      = "arn:aws:lambda:us-east-1:${var.member_account_id}:function:${local.idp_callbacks_function}"
}
data "archive_file" "idp_callbacks" {
  type        = "zip"
  source_file = "${path.module}/idp-callbacks/handler.py"
  output_path = "${path.module}/.terraform/gate-idp-callbacks.zip"
}
resource "aws_iam_role" "idp_callbacks" {
  name = "HonuaGateIdpCallbacks"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}
resource "aws_cloudwatch_log_group" "idp_callbacks" {
  name              = "/aws/lambda/${local.idp_callbacks_function}"
  retention_in_days = 14
}
resource "aws_iam_role_policy" "idp_callbacks" {
  name = "gate-idp-callbacks-only"
  role = aws_iam_role.idp_callbacks.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "cloudformation:ListStacks", Resource = "*" }, {
      Effect = "Allow", Action = ["cloudformation:DescribeStacks", "cloudformation:ListStackResources"], Resource = local.stack_arn
      }, {
      # Only to confirm a callback host is the default domain of a distribution the stack owns.
      Effect = "Allow", Action = "cloudfront:GetDistribution", Resource = "arn:aws:cloudfront::${var.member_account_id}:distribution/*"
      }, {
      # DescribeUserPoolClient returns the client secret; the handler never logs or returns it.
      Effect   = "Allow", Action = ["cognito-idp:DescribeUserPoolClient", "cognito-idp:UpdateUserPoolClient"]
      Resource = aws_cognito_user_pool.gate.arn
      }, {
      Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.idp_callbacks.arn}:*"
    }]
  })
}
resource "aws_lambda_function" "idp_callbacks" {
  function_name    = local.idp_callbacks_function
  role             = aws_iam_role.idp_callbacks.arn
  runtime          = "python3.13"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.idp_callbacks.output_path
  source_code_hash = data.archive_file.idp_callbacks.output_base64sha256
  timeout          = 60
  memory_size      = 128
  # One writer at a time: each run rewrites the whole callback list from live stacks.
  reserved_concurrent_executions = 1
  environment {
    variables = {
      USER_POOL_ID         = aws_cognito_user_pool.gate.id
      CLIENT_ID            = aws_cognito_user_pool_client.gate.id
      STATIC_CALLBACK_URLS = jsonencode(sort(tolist(var.idp_callback_urls)))
      SERVICE_ROLE_ARN     = local.service_role_arn
    }
  }
  depends_on = [aws_iam_role_policy.idp_callbacks]
}
