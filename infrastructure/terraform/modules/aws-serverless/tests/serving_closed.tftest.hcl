# serving_closed (honua-server#6750): on the Lambda + Batch release cell an
# internet scanner hit the API Gateway URL before the out-of-band migration
# finished; the cold-started instance entered schema-floor and never recovered.
# serving_closed holds the API and control-plane event functions at reserved
# concurrency 0 for the first apply; the second apply opens them. Only reserved
# concurrency may differ between the two: pool sizing and environments are
# derived from the open values.

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

run "open_by_default_is_unchanged" {
  command = apply

  assert {
    condition = (
      var.serving_closed == false &&
      output.serving_reserved_concurrency.closed == false &&
      output.serving_reserved_concurrency.api == null &&
      output.serving_reserved_concurrency.control_plane == { reconcile = 2, backstop = 1, tick = 1 }
    )
    error_message = "serving_closed must default to false and leave the API unreserved and the event functions at 2 / 1 / 1."
  }

  assert {
    condition = (
      aws_lambda_function.control_plane_reconcile[0].reserved_concurrent_executions == 2 &&
      aws_lambda_function.control_plane_backstop[0].reserved_concurrent_executions == 1 &&
      aws_lambda_function.control_plane_tick[0].reserved_concurrent_executions == 1
    )
    error_message = "Open, the event functions must keep their configured reserved concurrency."
  }
}

run "open_sized" {
  command = apply

  variables {
    db_instance_class                     = "db.r6g.large"
    lambda_reserved_concurrent_executions = 25
  }

  assert {
    condition = (
      aws_lambda_function.this.reserved_concurrent_executions == 25 &&
      output.serving_reserved_concurrency.api == 25 &&
      output.db_connection_budget.source == "derived" &&
      output.db_connection_budget.max_processes == 25
    )
    error_message = "Open, the API function must keep lambda_reserved_concurrent_executions and size its pool from it."
  }
}

run "closed_holds_every_serving_function_at_zero" {
  command = apply

  variables {
    db_instance_class                     = "db.r6g.large"
    lambda_reserved_concurrent_executions = 25
    serving_closed                        = true
  }

  assert {
    condition = (
      aws_lambda_function.this.reserved_concurrent_executions == 0 &&
      aws_lambda_function.control_plane_reconcile[0].reserved_concurrent_executions == 0 &&
      aws_lambda_function.control_plane_backstop[0].reserved_concurrent_executions == 0 &&
      aws_lambda_function.control_plane_tick[0].reserved_concurrent_executions == 0
    )
    error_message = "serving_closed must set reserved concurrency 0 on the API and all three control-plane event functions."
  }

  assert {
    condition = (
      output.serving_reserved_concurrency.closed == true &&
      output.serving_reserved_concurrency.api == 0 &&
      output.serving_reserved_concurrency.control_plane == { reconcile = 0, backstop = 0, tick = 0 }
    )
    error_message = "The serving_reserved_concurrency output must report the closed deployment."
  }

  assert {
    condition     = output.db_connection_budget == run.open_sized.db_connection_budget
    error_message = "Closing must not change database pool sizing: it is derived from the open reserved concurrency."
  }

  assert {
    condition = (
      aws_lambda_function.this.environment[0].variables["Limits__Connections__MaxConnectionPoolSize"] == tostring(run.open_sized.db_connection_budget.pool_size) &&
      strcontains(aws_secretsmanager_secret_version.connection_string.secret_string, ";Maximum Pool Size=${run.open_sized.db_connection_budget.pool_size};")
    )
    error_message = "Closed, the API environment and connection string must carry the open pool size, so opening changes only reserved concurrency."
  }
}

run "closed_without_control_plane_events_closes_the_api" {
  command = plan

  variables {
    enable_control_plane_events = false
    serving_closed              = true
  }

  assert {
    condition = (
      aws_lambda_function.this.reserved_concurrent_executions == 0 &&
      output.serving_reserved_concurrency.control_plane == null
    )
    error_message = "serving_closed must close the API function when the control-plane event functions are disabled."
  }
}

run "zero_reserved_concurrency_does_not_size_the_pool" {
  command = plan

  variables {
    db_instance_class                     = "db.r6g.large"
    lambda_reserved_concurrent_executions = 0
  }

  assert {
    condition = (
      aws_lambda_function.this.reserved_concurrent_executions == 0 &&
      output.db_connection_budget.source == "fallback" &&
      output.db_connection_budget.pool_size == 8
    )
    error_message = "A reserved concurrency of 0 is a closed function: it must plan (no division by zero) with the fallback pool."
  }
}
