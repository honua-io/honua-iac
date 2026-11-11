provider "aws" { region = var.region }

# GitHub organisation webhook -> Lambda function URL (HMAC verified) -> SQS -> ci-dispatch on the lane host.
# No model calls run in AWS: fixers run on the lane host under the existing subscription logins.

locals {
  tags = {
    Environment = "it"
    Owner       = "lane-agents"
    ManagedBy   = "terraform"
    Purpose     = "ci-events"
  }
}

data "aws_caller_identity" "current" {}

resource "aws_sqs_queue" "dead_letter" {
  name                      = "${var.name}-dlq"
  message_retention_seconds = var.message_retention_seconds
  sqs_managed_sse_enabled   = true
  tags                      = local.tags
}

resource "aws_sqs_queue" "events" {
  name                       = var.name
  message_retention_seconds  = var.message_retention_seconds
  receive_wait_time_seconds  = 20
  visibility_timeout_seconds = 120
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter.arn
    maxReceiveCount     = var.max_receive_count
  })
  tags = local.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "dead_letter" {
  queue_url = aws_sqs_queue.dead_letter.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.events.arn]
  })
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "receiver" {
  name_prefix        = "${var.name}-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

resource "aws_cloudwatch_log_group" "receiver" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

data "aws_iam_policy_document" "receiver" {
  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.receiver.arn}:*"]
  }
  statement {
    sid       = "ReadWebhookSecret"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.webhook_secret_parameter}"]
  }
  dynamic "statement" {
    for_each = var.webhook_secret_kms_key_arn == "" ? [] : [var.webhook_secret_kms_key_arn]
    content {
      sid       = "DecryptWebhookSecret"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]
    }
  }
  statement {
    sid       = "SendEvents"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.events.arn]
  }
}

resource "aws_iam_role_policy" "receiver" {
  name   = "ci-events-receiver"
  role   = aws_iam_role.receiver.id
  policy = data.aws_iam_policy_document.receiver.json
}

data "archive_file" "receiver" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/build/receiver.zip"
}

resource "aws_lambda_function" "receiver" {
  function_name    = var.name
  description      = "GitHub org webhook: verify X-Hub-Signature-256, filter, forward a compact event to SQS."
  role             = aws_iam_role.receiver.arn
  filename         = data.archive_file.receiver.output_path
  source_code_hash = data.archive_file.receiver.output_base64sha256
  handler          = "handler.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = 10
  memory_size      = 128

  reserved_concurrent_executions = var.reserved_concurrency

  environment {
    variables = {
      WEBHOOK_SECRET_PARAM = var.webhook_secret_parameter
      QUEUE_URL            = aws_sqs_queue.events.url
      ALLOWED_REPOS        = join(",", var.allowed_repos)
      IGNORE_SENDERS       = join(",", var.ignore_senders)
    }
  }

  depends_on = [aws_cloudwatch_log_group.receiver, aws_iam_role_policy.receiver]
  tags       = local.tags
}

# GitHub cannot sign AWS requests, so the URL is public; every request is authenticated by the
# webhook HMAC before anything is queued.
resource "aws_lambda_function_url" "receiver" {
  function_name      = aws_lambda_function.receiver.function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "public_function_url" {
  statement_id           = "AllowGitHubWebhookFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.receiver.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# Since October 2025 a public function URL also needs lambda:InvokeFunction, scoped to calls that arrive
# through the URL (without the condition any AWS account could invoke the function directly).
resource "aws_lambda_permission" "public_function_url_invoke" {
  statement_id             = "AllowGitHubWebhookInvokeViaUrl"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.receiver.function_name
  principal                = "*"
  invoked_via_function_url = true
}
