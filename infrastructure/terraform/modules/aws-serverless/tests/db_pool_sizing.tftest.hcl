# Database pool sizing (db-pool-sizing.tf; README: Database connection sizing).
# The public demo (db.t4g.small, reserved concurrency 25, no RDS Proxy) left
# every API Lambda environment at the server's 200-connection pools: bursts
# reached DatabaseConnections 175 and PostgreSQL 53300, and FeatureServer
# answered "Query execution failed" inside HTTP 200. The API pool is now
# derived from the instance class and reserved concurrency; without a bound
# it keeps the previous fixed 8.
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

  redis_enabled = false
}

run "unbounded_concurrency_keeps_the_previous_cap" {
  command = apply

  assert {
    condition     = output.db_connection_budget.source == "fallback" && output.db_connection_budget.pool_size == 8
    error_message = "Without lambda_reserved_concurrent_executions the API pool must stay at the previous fixed 8."
  }

  assert {
    condition = (
      aws_lambda_function.this.environment[0].variables["Limits__Connections__MaxConnectionPoolSize"] == "8" &&
      aws_lambda_function.this.environment[0].variables["Limits__Connections__MaxConcurrentQueries"] == "8" &&
      !contains(keys(aws_lambda_function.this.environment[0].variables), "Limits__Connections__MinConnectionPoolSize")
    )
    error_message = "The default Lambda environment must keep exactly the previous pool keys and values."
  }
}

# Worked example from the README: db.t4g.small x 25 reserved concurrency.
# max_connections 168 (75% of 2 GiB / 9531392), 163 usable after 5 reserved,
# floor(163 x 0.85) = 138, / (25 x 2 pools) = 2.
run "demo_shape_is_sized_from_class_and_concurrency" {
  command = apply

  variables {
    db_instance_class                     = "db.t4g.small"
    lambda_reserved_concurrent_executions = 25
  }

  assert {
    condition = (
      output.db_connection_budget.max_connections == 168 &&
      output.db_connection_budget.usable_connections == 163 &&
      output.db_connection_budget.max_processes == 25 &&
      output.db_connection_budget.pool_size == 2 &&
      output.db_connection_budget.source == "derived" &&
      output.db_connection_budget.worst_case_connections == 100
    )
    error_message = "db.t4g.small x 25 must derive a pool of 2 (worst case 100 of 163 usable)."
  }

  assert {
    condition = (
      aws_lambda_function.this.environment[0].variables["Limits__Connections__MaxConnectionPoolSize"] == "2" &&
      aws_lambda_function.this.environment[0].variables["Limits__Connections__MaxConcurrentQueries"] == "2"
    )
    error_message = "The derived cap must reach the API Lambda."
  }

  assert {
    condition     = strcontains(aws_secretsmanager_secret_version.connection_string.secret_string, ";Maximum Pool Size=2;")
    error_message = "The module-built connection string must carry the derived cap."
  }
}

run "larger_instance_is_clamped_to_the_server_default" {
  command = plan

  variables {
    db_instance_class                     = "db.r6g.4xlarge"
    lambda_reserved_concurrent_executions = 5
  }

  assert {
    condition     = output.db_connection_budget.max_connections == 5000 && output.db_connection_budget.pool_size == 200
    error_message = "max_connections is capped at 5000 and the pool at the server default of 200."
  }
}

# Control-plane functions (2 + 1 + 1 instances x 2 x 2 pools = 16) and GP Batch
# (4 vCPUs / 1 = 4 jobs x 4 x 2 pools = 32) come off the API's budget first:
# (138 - 48) / 50 = 1.
run "fixed_consumers_come_off_the_budget" {
  command = apply

  variables {
    db_instance_class                     = "db.t4g.small"
    lambda_reserved_concurrent_executions = 25
    enable_control_plane_events           = true
    enable_gp_batch                       = true
    gp_batch_max_vcpus                    = 4
  }

  assert {
    condition     = output.db_connection_budget.other_connections == 48 && output.db_connection_budget.pool_size == 1 && output.db_connection_budget.worst_case_connections == 98
    error_message = "Control-plane and GP Batch connections must be counted before the API pool is sized."
  }
}

# At the default 16 GP vCPUs the fixed consumers alone take 144, so even a
# pool of 1 (25 x 2 + 144 = 194) exceeds the 163 usable connections.
run "infeasible_budget_fails_plan" {
  command = plan

  variables {
    db_instance_class                     = "db.t4g.small"
    lambda_reserved_concurrent_executions = 25
    enable_control_plane_events           = true
    enable_gp_batch                       = true
  }

  expect_failures = [output.db_connection_budget]
}

run "oversized_override_fails_plan" {
  command = plan

  variables {
    db_instance_class                     = "db.t4g.small"
    lambda_reserved_concurrent_executions = 25
    lambda_db_max_pool_size               = 8
  }

  expect_failures = [output.db_connection_budget]
}

run "fitting_override_wins" {
  command = plan

  variables {
    db_instance_class                     = "db.t4g.small"
    lambda_reserved_concurrent_executions = 25
    lambda_db_max_pool_size               = 3
  }

  assert {
    condition     = output.db_connection_budget.source == "override" && output.db_connection_budget.pool_size == 3 && output.db_connection_budget.worst_case_connections == 150
    error_message = "A fitting lambda_db_max_pool_size must be used as is."
  }
}

run "rds_proxy_keeps_the_previous_cap_and_skips_the_check" {
  # enable_rds_proxy changes the settings document (Database:QueryCache); a
  # fresh state keeps this run from planning to destroy the retained default one.
  state_key = "rds_proxy"
  command   = plan

  variables {
    db_instance_class                     = "db.t4g.small"
    lambda_reserved_concurrent_executions = 25
    enable_rds_proxy                      = true
    lambda_db_max_pool_size               = 8
    # checkov:skip=CKV_SECRET_6: Synthetic test-only database password for mocked providers, not a credential.
    db_password = "Synthetic-Terraform-Test-Db-Password-1"
  }

  assert {
    condition     = output.db_connection_budget.pooler_enabled && output.db_connection_budget.pool_size == 8
    error_message = "Behind RDS Proxy the server connects to the proxy, so the database budget does not bound the pool."
  }
}

run "existing_database_needs_max_connections_override" {
  command = plan

  variables {
    existing_db_endpoint                  = "postgres.example.internal"
    existing_db_connection_string         = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"
    lambda_reserved_concurrent_executions = 10
    db_max_connections_override           = 500
  }

  # (floor(495 x 0.85) = 420) / (10 x 2) = 21
  assert {
    condition     = output.db_connection_budget.pool_size == 21 && output.db_connection_budget.source == "derived"
    error_message = "db_max_connections_override must size the pools for an existing database."
  }
}

run "unknown_instance_class_keeps_the_previous_cap" {
  command = plan

  variables {
    db_instance_class                     = "db.x2g.large"
    lambda_reserved_concurrent_executions = 25
  }

  assert {
    condition     = output.db_connection_budget.max_connections == null && output.db_connection_budget.pool_size == 8
    error_message = "An instance class missing from the table must keep the previous cap, not guess."
  }
}

run "safety_fraction_out_of_range_is_rejected" {
  command = plan

  variables {
    db_connection_safety_fraction = 1.5
  }

  expect_failures = [var.db_connection_safety_fraction]
}

# Redis client timeouts (README: Redis connections): the module-built string
# carries explicit connectTimeout, syncTimeout and keepAlive; a caller's
# string is stored unchanged. The value lives in Secrets Manager, not in the
# 4 KB Lambda environment.
run "module_built_redis_string_carries_client_timeouts" {
  command = apply

  variables {
    redis_enabled = true
    # checkov:skip=CKV_SECRET_6: Synthetic test-only Redis token for mocked providers, not a credential.
    redis_auth_token                          = "SyntheticRedisToken0123456789abcdef"
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  }

  assert {
    condition     = endswith(aws_secretsmanager_secret_version.redis_connection[0].secret_string, ",ssl=true,connectTimeout=10000,syncTimeout=10000,keepAlive=60")
    error_message = "The module-built Redis string must end with the serverless client timeouts."
  }
}

run "caller_redis_string_is_not_rewritten" {
  command = apply

  variables {
    redis_connection_string                   = "redis.example.internal:6379,password=test,ssl=true"
    redis_connection_cidrs                    = ["10.0.0.0/16"]
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  }

  assert {
    condition     = aws_secretsmanager_secret_version.redis_connection[0].secret_string == "redis.example.internal:6379,password=test,ssl=true"
    error_message = "A caller-supplied Redis connection string must be stored unchanged."
  }
}
