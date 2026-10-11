# Database pool caps (honua-release e2e-cloud-aws run 38107383082,
# aws-serverless/redis-on): every warm Lambda instance and GP Batch job opened
# its own Npgsql pools with the server's defaults (MaxConnectionPoolSize 200,
# MinConnectionPoolSize 20), and the db.t3.micro ran out of slots
# ("53300: remaining connection slots are reserved").
#
# The server's main NpgsqlDataSource takes its bounds from Limits:Connections,
# so each process gets its cap in the environment; the module-built connection
# string carries the same keywords for pools opened straight from it.

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

run "defaults_cap_every_process" {
  command = apply

  assert {
    condition     = aws_lambda_function.this.environment[0].variables["Limits__Connections__MaxConnectionPoolSize"] == "8"
    error_message = "The API Lambda must cap its pool at lambda_db_max_pool_size (default 8)."
  }

  assert {
    condition = alltrue([
      for fn in [aws_lambda_function.control_plane_reconcile[0], aws_lambda_function.control_plane_backstop[0], aws_lambda_function.control_plane_tick[0]] :
      fn.environment[0].variables["Limits__Connections__MaxConnectionPoolSize"] == "2"
    ])
    error_message = "Each control-plane event Lambda must cap its pool at control_plane_db_max_pool_size (default 2), not the API's."
  }

  assert {
    condition = alltrue([
      for tier, jd in aws_batch_job_definition.gp : {
        for e in jsondecode(jd.container_properties).environment : e.name => e.value if startswith(e.name, "Limits__Connections__")
        } == {
        Limits__Connections__MaxConnectionPoolSize         = "4"
        Limits__Connections__MinConnectionPoolSize         = "0"
        Limits__Connections__ConnectionIdleLifetimeSeconds = "60"
      }
    ])
    error_message = "Every GP job-definition tier must cap its pool at gp_batch_db_max_pool_size (default 4) with MinConnectionPoolSize 0 and the idle lifetime."
  }

  assert {
    condition     = endswith(aws_secretsmanager_secret_version.connection_string.secret_string, ";Maximum Pool Size=8;Connection Idle Lifetime=60;Connection Pruning Interval=10;Timeout=15")
    error_message = "The module-built connection string must end with the pool keywords."
  }
}

run "overrides_reach_every_process" {
  command = apply

  variables {
    lambda_db_max_pool_size             = 12
    control_plane_db_max_pool_size      = 3
    gp_batch_db_max_pool_size           = 6
    db_connection_idle_lifetime_seconds = 120
    db_connection_string_options        = "Maximum Pool Size=5"
  }

  assert {
    condition = (
      aws_lambda_function.this.environment[0].variables["Limits__Connections__MaxConnectionPoolSize"] == "12" &&
      aws_lambda_function.control_plane_tick[0].environment[0].variables["Limits__Connections__MaxConnectionPoolSize"] == "3"
    )
    error_message = "Pool size overrides must reach the API and control-plane Lambdas."
  }

  assert {
    condition = alltrue([
      for tier, jd in aws_batch_job_definition.gp :
      one([for e in jsondecode(jd.container_properties).environment : e.value if e.name == "Limits__Connections__MaxConnectionPoolSize"]) == "6" &&
      one([for e in jsondecode(jd.container_properties).environment : e.value if e.name == "Limits__Connections__ConnectionIdleLifetimeSeconds"]) == "120"
    ])
    error_message = "Pool size and idle lifetime overrides must reach the GP job definitions."
  }

  assert {
    condition     = endswith(aws_secretsmanager_secret_version.connection_string.secret_string, ";Maximum Pool Size=12;Connection Idle Lifetime=120;Connection Pruning Interval=10;Timeout=15;Maximum Pool Size=5")
    error_message = "db_connection_string_options must follow the pool keywords so an operator keyword wins."
  }
}

run "existing_connection_string_is_not_rewritten" {
  command = apply

  variables {
    enable_gp_batch               = false
    enable_control_plane_events   = false
    existing_db_endpoint          = "postgres.example.internal"
    existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"
  }

  assert {
    condition     = aws_secretsmanager_secret_version.connection_string.secret_string == "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"
    error_message = "An operator-supplied connection string must be stored unchanged."
  }

  assert {
    condition     = aws_lambda_function.this.environment[0].variables["Limits__Connections__MaxConnectionPoolSize"] == "8"
    error_message = "The environment cap must still apply with an existing database."
  }
}

run "idle_lifetime_below_the_pruning_interval_is_rejected" {
  command = plan

  variables {
    db_connection_idle_lifetime_seconds = 5
  }

  expect_failures = [var.db_connection_idle_lifetime_seconds]
}

run "zero_pool_size_is_rejected" {
  command = plan

  variables {
    lambda_db_max_pool_size = 0
  }

  expect_failures = [var.lambda_db_max_pool_size]
}
