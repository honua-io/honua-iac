# Lead-capture forms router: honua.io site forms -> Attio CRM.
#
# Standalone internal stack with its own (local) state. Completely independent
# of the operator example stacks — do not wire it into their modules or state.

provider "aws" {
  region = var.region
}

locals {
  function_name = var.name_prefix
}

# ---------------------------------------------------------------------------
# Attio API key secret. Terraform owns the container only; the real value is
# set out of band with `aws secretsmanager put-secret-value` and never lives
# in state or VCS.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "attio_api_key" {
  name        = var.attio_secret_name
  description = "Attio API key for the honua.io lead-capture forms router. Value is managed out of band."
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "attio_api_key_placeholder" {
  secret_id     = aws_secretsmanager_secret.attio_api_key.id
  secret_string = "REPLACE_ME"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ---------------------------------------------------------------------------
# Loops.so API key secret. Same out-of-band pattern as the Attio key: Terraform
# owns the container and a placeholder only; the real value is set with
# `aws secretsmanager put-secret-value` and never lives in state or VCS. Leaving
# the placeholder in place disables the Loops code path at runtime.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "loops_api_key" {
  name        = var.loops_secret_name
  description = "Loops.so API key for the honua.io lead-capture forms router. Value is managed out of band; placeholder disables Loops."
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "loops_api_key_placeholder" {
  secret_id     = aws_secretsmanager_secret.loops_api_key.id
  secret_string = "REPLACE_ME"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ---------------------------------------------------------------------------
# Lambda execution role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "forms_router" {
  name               = "${var.name_prefix}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "forms_router" {
  statement {
    sid     = "Logs"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "${aws_cloudwatch_log_group.forms_router.arn}:*",
    ]
  }

  statement {
    sid     = "ReadFormsRouterSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.attio_api_key.arn,
      aws_secretsmanager_secret.loops_api_key.arn,
    ]
  }
}

resource "aws_iam_role_policy" "forms_router" {
  name   = "${var.name_prefix}-policy"
  role   = aws_iam_role.forms_router.id
  policy = data.aws_iam_policy_document.forms_router.json
}

# ---------------------------------------------------------------------------
# Lambda function + URL
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "forms_router" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

data "archive_file" "forms_router" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/forms-router.zip"
}

resource "aws_lambda_function" "forms_router" {
  function_name = local.function_name
  description   = "Routes honua.io form submissions (contact / waitlist / newsletter) into Attio."
  role          = aws_iam_role.forms_router.arn

  filename         = data.archive_file.forms_router.output_path
  source_code_hash = data.archive_file.forms_router.output_base64sha256

  handler       = "index.handler"
  runtime       = "nodejs22.x"
  architectures = ["arm64"]
  # 29s leaves margin above the handler's 12s shared upstream deadline
  # (INVOCATION_DEADLINE_MS in src/index.mjs) so the function always returns its
  # own structured 502 + "lead routing failed" log before Lambda hard-kills it.
  timeout     = 29
  memory_size = 256

  reserved_concurrent_executions = var.reserved_concurrency

  environment {
    variables = {
      ATTIO_SECRET_ARN      = aws_secretsmanager_secret.attio_api_key.arn
      ATTIO_WAITLIST_LIST   = var.attio_waitlist_list
      ATTIO_NEWSLETTER_LIST = var.attio_newsletter_list
      ALLOWED_ORIGIN        = var.allowed_origin
      LOOPS_SECRET_ARN      = aws_secretsmanager_secret.loops_api_key.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.forms_router]

  tags = var.tags
}

resource "aws_lambda_function_url" "forms_router" {
  function_name      = aws_lambda_function.forms_router.function_name
  authorization_type = "NONE"

  cors {
    allow_origins     = [var.allowed_origin]
    allow_methods     = ["POST"]
    allow_headers     = ["content-type"]
    max_age           = 86400
    allow_credentials = false
  }
}

resource "aws_lambda_permission" "public_function_url" {
  statement_id           = "AllowPublicFunctionUrlInvoke"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.forms_router.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}
