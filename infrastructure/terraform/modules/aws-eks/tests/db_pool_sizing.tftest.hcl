# Database pool sizing (db-pool-sizing.tf; README: Database connection sizing).


mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
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

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_region" {
    defaults = {
      id     = "us-east-1"
      name   = "us-east-1"
      region = "us-east-1"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "tls" {}
mock_provider "time" {}
mock_provider "cloudinit" {}
mock_provider "null" {}
mock_provider "random" {}

# Pin the module-owned secret ARNs at plan time so policy and environment
# assertions compare known values.
override_resource {
  target          = aws_secretsmanager_secret.db_connection
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-db-AAAAAA"
  }
}

override_resource {
  target          = aws_secretsmanager_secret.admin_password
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-admin-BBBBBB"
  }
}

override_resource {
  target          = aws_secretsmanager_secret.master_key
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-connection-encryption-CCCCCC"
  }
}

override_resource {
  target          = aws_secretsmanager_secret.redis_connection
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-redis-DDDDDD"
  }
}

variables {
  name_prefix = "honua"
  environment = "test"

  cluster_secret_encryption_enabled = false
  audit_chain_key_secret_arn        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
}


run "unset_replica_ceiling_renders_no_pool_keys" {
  command = plan

  assert {
    condition = output.db_connection_budget.source == "server-default" && length([
      for name in keys(output.chart_config_env) : name if startswith(name, "Limits__Connections__")
    ]) == 0
    error_message = "Without server_max_replicas the module does not know the replica count and must render no pool keys."
  }
}

# db.t3.micro: 84 max, 79 usable, 67 budget; 4 replicas + 1 surge = 5,
# / (5 x 2 pools) = 6.
run "replica_ceiling_sizes_the_chart_environment" {
  command = plan

  variables {
    server_max_replicas = 4
  }

  assert {
    condition = (
      output.db_connection_budget.max_processes == 5 &&
      output.chart_config_env["Limits__Connections__MaxConnectionPoolSize"] == "6" &&
      output.chart_config_env["Limits__Connections__MaxConcurrentQueries"] == "6" &&
      output.chart_config_env["Limits__Connections__MinConnectionPoolSize"] == "6" &&
      output.honua_server_environment["Limits__Connections__MaxConnectionPoolSize"] == "6"
    )
    error_message = "server_max_replicas must size the pools in chart_config_env and honua_server_environment."
  }
}

run "infeasible_replica_ceiling_fails_plan" {
  command = plan

  variables {
    server_max_replicas = 40
  }

  expect_failures = [output.db_connection_budget]
}
