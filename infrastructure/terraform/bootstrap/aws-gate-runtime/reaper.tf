data "archive_file" "reaper" {
  type        = "zip"
  source_file = "${path.module}/reaper/handler.py"
  output_path = "${path.module}/.terraform/gate-reaper.zip"
}
resource "aws_iam_role" "reaper" {
  name = "HonuaGateReaper"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}
resource "aws_cloudwatch_log_group" "reaper" {
  name              = "/aws/lambda/honua-gate-reaper"
  retention_in_days = 14
}
resource "aws_iam_role_policy" "reaper" {
  name = "expired-gate-stacks-only"
  role = aws_iam_role.reaper.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "cloudformation:ListStacks", Resource = "*" }, {
      Effect = "Allow", Action = "cloudformation:DescribeStacks", Resource = local.stack_arn
      }, {
      Effect    = "Allow", Action = "cloudformation:DeleteStack", Resource = local.stack_arn
      Condition = { StringEquals = { "cloudformation:RoleArn" = local.service_role_arn } }
      }, {
      Effect    = "Allow", Action = "iam:PassRole", Resource = local.service_role_arn
      Condition = { StringEquals = { "iam:PassedToService" = "cloudformation.amazonaws.com" } }
      }, {
      Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.reaper.arn}:*"
    }]
  })
}
resource "aws_lambda_function" "reaper" {
  function_name                  = "honua-gate-reaper"
  role                           = aws_iam_role.reaper.arn
  runtime                        = "python3.13"
  handler                        = "handler.lambda_handler"
  filename                       = data.archive_file.reaper.output_path
  source_code_hash               = data.archive_file.reaper.output_base64sha256
  timeout                        = 300
  memory_size                    = 128
  reserved_concurrent_executions = 1
  environment { variables = { SERVICE_ROLE_ARN = local.service_role_arn } }
  depends_on = [aws_iam_role_policy.reaper]
}
resource "aws_cloudwatch_event_rule" "nightly" {
  name                = "honua-gate-nightly-reaper"
  schedule_expression = "cron(0 3 * * ? *)"
  state               = "ENABLED"
}
resource "aws_cloudwatch_event_target" "reaper" {
  rule = aws_cloudwatch_event_rule.nightly.name
  arn  = aws_lambda_function.reaper.arn
}
resource "aws_lambda_permission" "nightly" {
  statement_id   = "NightlyGateCleanup"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.reaper.function_name
  principal      = "events.amazonaws.com"
  source_arn     = aws_cloudwatch_event_rule.nightly.arn
  source_account = var.member_account_id
}
