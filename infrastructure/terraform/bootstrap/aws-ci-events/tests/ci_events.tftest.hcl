mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = {
      arn = "arn:aws:sqs:eu-north-1:123456789012:honua-ci-events"
      url = "https://sqs.eu-north-1.amazonaws.com/123456789012/honua-ci-events"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:eu-north-1:123456789012:log-group:/aws/lambda/honua-ci-events" }
  }
}

override_resource {
  target          = aws_sqs_queue.dead_letter
  override_during = plan
  values          = { arn = "arn:aws:sqs:eu-north-1:123456789012:honua-ci-events-dlq" }
}

override_data {
  target = data.aws_iam_policy_document.lambda_assume
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}
override_data {
  target = data.aws_iam_policy_document.receiver
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

run "receiver_queue_and_dead_letter" {
  command = plan
  assert {
    condition     = aws_sqs_queue.events.message_retention_seconds == 345600 && aws_sqs_queue.dead_letter.message_retention_seconds == 345600
    error_message = "Queue and dead-letter queue keep messages for 4 days."
  }
  assert {
    condition     = jsondecode(aws_sqs_queue.events.redrive_policy).maxReceiveCount == 5
    error_message = "Messages move to the dead-letter queue after 5 receives."
  }
  assert {
    condition     = aws_sqs_queue.events.receive_wait_time_seconds == 20 && aws_sqs_queue.events.sqs_managed_sse_enabled
    error_message = "The queue long-polls and is encrypted."
  }
  assert {
    condition     = aws_lambda_function.receiver.runtime == "python3.12" && aws_lambda_function.receiver.handler == "handler.handler"
    error_message = "The receiver is the dependency-free Python handler."
  }
  assert {
    condition     = aws_lambda_function.receiver.environment[0].variables.WEBHOOK_SECRET_PARAM == "/honua/ci-events/webhook-secret"
    error_message = "The webhook secret is read from SSM at run time, never placed in state."
  }
  assert {
    condition     = aws_lambda_function_url.receiver.authorization_type == "NONE" && aws_lambda_permission.public_function_url.function_url_auth_type == "NONE"
    error_message = "GitHub cannot sign AWS requests: the URL is public and the handler checks the HMAC."
  }
  assert {
    condition     = aws_lambda_function.receiver.reserved_concurrent_executions == 20
    error_message = "Receiver concurrency is capped."
  }
}
