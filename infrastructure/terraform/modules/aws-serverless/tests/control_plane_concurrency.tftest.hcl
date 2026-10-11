# Control-plane concurrency (honua-release e2e-cloud-aws run 38125145738,
# aws-serverless/redis-on): the scheduled-tick function exhausted RDS
# ("53300: remaining connection slots are reserved", "PostGIS preflight check
# failed ... Startup aborted"). EventBridge Scheduler fires one tick per kind,
# each overlapping invocation started a new instance with its own pool, and
# frozen instances keep their connections. Reserved concurrency bounds the
# instances; throttled invocations wait in Lambda's asynchronous queue and the
# schedules retry failed deliveries, so a tick is delayed, not dropped.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      id     = "us-east-1"
      name   = "us-east-1"
      region = "us-east-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      dns_suffix         = "amazonaws.com"
      id                 = "aws"
      partition          = "aws"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:us-east-1:123456789012:repository/honua-server"
      registry_id    = "123456789012"
      repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/honua-test"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/honua-test"
    }
  }

  mock_resource "aws_batch_compute_environment" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:123456789012:compute-environment/honua-mock"
    }
  }

  mock_resource "aws_batch_job_queue" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:123456789012:job-queue/honua-mock"
    }
  }

  mock_resource "aws_batch_job_definition" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:123456789012:job-definition/honua-mock:1"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:honua-mock:*"
    }
  }

  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      arn           = "arn:aws:apigateway:us-east-1::/apis/abcdefghij"
      execution_arn = "arn:aws:execute-api:us-east-1:123456789012:abcdefghij"
    }
  }

  # Control-plane event targets and schedules validate these ARNs in-provider.
  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:123456789012:function:honua-mock"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-1:123456789012:rule/honua-mock"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-mock-AbCdEf"
    }
  }
}

mock_provider "random" {}
mock_provider "null" {}

variables {
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"

  image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password = "Synthetic-Terraform-Test-Admin-4721!aA1"

  redis_enabled               = false
  enable_control_plane_events = true
  enable_gp_batch             = true
}

run "defaults_bound_every_event_function" {
  command = apply

  assert {
    condition = (
      aws_lambda_function.control_plane_reconcile[0].reserved_concurrent_executions == 2 &&
      aws_lambda_function.control_plane_backstop[0].reserved_concurrent_executions == 1 &&
      aws_lambda_function.control_plane_tick[0].reserved_concurrent_executions == 1
    )
    error_message = "The reconcile, backstop and tick functions must default to reserved concurrency 2, 1 and 1."
  }

  assert {
    condition = alltrue([
      for kind, schedule in aws_scheduler_schedule.control_plane_tick :
      schedule.target[0].retry_policy[0].maximum_retry_attempts == 10 &&
      schedule.target[0].retry_policy[0].maximum_event_age_in_seconds == 900
    ]) && length(aws_scheduler_schedule.control_plane_tick) == 8
    error_message = "Every tick schedule must retry failed deliveries (10 attempts within 900 seconds)."
  }

  assert {
    condition = (
      aws_scheduler_schedule.control_plane_backstop[0].target[0].retry_policy[0].maximum_retry_attempts == 10 &&
      aws_scheduler_schedule.control_plane_backstop[0].target[0].retry_policy[0].maximum_event_age_in_seconds == 600
    )
    error_message = "The backstop schedule must retry failed deliveries (10 attempts within 600 seconds)."
  }

  assert {
    condition = (
      aws_lambda_function_event_invoke_config.control_plane_tick[0].function_name == aws_lambda_function.control_plane_tick[0].function_name &&
      aws_lambda_function_event_invoke_config.control_plane_tick[0].maximum_event_age_in_seconds == 900 &&
      aws_lambda_function_event_invoke_config.control_plane_backstop[0].function_name == aws_lambda_function.control_plane_backstop[0].function_name &&
      aws_lambda_function_event_invoke_config.control_plane_backstop[0].maximum_event_age_in_seconds == 600
    )
    error_message = "Throttled tick and backstop invocations must be kept in Lambda's asynchronous queue (900 and 600 seconds)."
  }
}

run "per_function_overrides" {
  command = apply

  variables {
    control_plane_reconcile_reserved_concurrency = 3
    control_plane_backstop_reserved_concurrency  = 2
    control_plane_tick_reserved_concurrency      = 2
  }

  assert {
    condition = (
      aws_lambda_function.control_plane_reconcile[0].reserved_concurrent_executions == 3 &&
      aws_lambda_function.control_plane_backstop[0].reserved_concurrent_executions == 2 &&
      aws_lambda_function.control_plane_tick[0].reserved_concurrent_executions == 2
    )
    error_message = "Per-function reserved concurrency overrides must reach each function."
  }
}

run "legacy_shared_setting_still_applies_to_all_three" {
  command = apply

  variables {
    control_plane_events_reserved_concurrent_executions = 4
  }

  assert {
    condition = alltrue([
      for fn in [aws_lambda_function.control_plane_reconcile[0], aws_lambda_function.control_plane_backstop[0], aws_lambda_function.control_plane_tick[0]] :
      fn.reserved_concurrent_executions == 4
    ])
    error_message = "control_plane_events_reserved_concurrent_executions, when set, must apply to all three functions."
  }
}

run "zero_reserved_concurrency_is_rejected" {
  command = plan

  variables {
    control_plane_tick_reserved_concurrency = 0
  }

  expect_failures = [var.control_plane_tick_reserved_concurrency]
}
