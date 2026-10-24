# Database pool sizing (db-pool-sizing.tf; README: Database connection sizing).
# Before this, ECS tasks ran honua-server's default 200-connection pools (two
# per process) against a db.t3.micro of about 87 max_connections.
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

  mock_data "aws_elb_service_account" {
    defaults = {
      arn = "arn:aws:iam::127311923021:root"
      id  = "127311923021"
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

  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/honua-test/0000000000000000"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/honua-test/0000000000000000"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/honua-test/0000000000000000/1111111111111111"
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
}

mock_provider "random" {}
mock_provider "null" {}

variables {
  audit_chain_key_secret_arn                = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
  operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  image                                     = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password                            = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  connection_encryption_master_key          = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  existing_vpc_id             = "vpc-0123456789abcdef0"
  existing_vpc_cidr           = "10.0.0.0/16"
  existing_public_subnet_ids  = ["subnet-00000000000000001", "subnet-00000000000000002"]
  existing_private_subnet_ids = ["subnet-00000000000000003", "subnet-00000000000000004"]

  redis_enabled           = false
  kms_key_arn             = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
  alb_access_logs_enabled = false
}

# db.t3.micro: max_connections 84 (75% of 1 GiB / 9531392), 79 usable,
# floor(79 x 0.85) = 67, / (1 task x 2 pools) = 33.
run "single_task_default_is_sized_from_the_instance_class" {
  command = apply

  assert {
    condition = (
      output.db_connection_budget.max_connections == 84 &&
      output.db_connection_budget.usable_connections == 79 &&
      output.db_connection_budget.max_processes == 1 &&
      output.db_connection_budget.pool_size == 33 &&
      output.db_connection_budget.source == "derived"
    )
    error_message = "The default single task on db.t3.micro must derive a pool of 33."
  }

  assert {
    condition = {
      for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment :
      entry.name => entry.value if startswith(entry.name, "Limits__Connections__")
      } == {
      Limits__Connections__MaxConnectionPoolSize = "33"
      Limits__Connections__MaxConcurrentQueries  = "33"
      Limits__Connections__MinConnectionPoolSize = "20"
    }
    error_message = "The task definition must carry exactly the three derived pool keys."
  }
}

# Migration task: one more process. (67) / (2 x 2) = 16.
run "migration_task_counts_as_a_process" {
  command = plan

  variables {
    migration_task = true
  }

  assert {
    condition     = output.db_connection_budget.max_processes == 2 && output.db_connection_budget.pool_size == 16
    error_message = "The one-off migration task must be counted."
  }
}

# MultiNode: max_capacity 4, doubled during a 200% rolling deployment = 8
# processes; db.t4g.medium 337 max, 332 usable, floor(282.2) = 282 / 16 = 17.
run "multinode_counts_max_capacity_and_deployment_surge" {
  command = plan

  variables {
    desired_count                   = 2
    max_capacity                    = 4
    deployment_mode                 = "MultiNode"
    redis_connection_string         = "redis.example.internal:6379,password=test,ssl=true"
    redis_connection_cidrs          = ["10.0.0.0/16"]
    file_storage_provider           = "AwsS3"
    file_storage_aws_s3_bucket_name = "honua-test-files"
    db_instance_class               = "db.t4g.medium"
  }

  assert {
    condition     = output.db_connection_budget.max_processes == 8 && output.db_connection_budget.pool_size == 17
    error_message = "MultiNode must size for max_capacity x 2 (deployment_maximum_percent 200)."
  }
}

run "existing_database_without_override_keeps_the_server_default" {
  command = apply

  variables {
    existing_db_endpoint          = "postgres.example.internal"
    existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"
  }

  assert {
    condition = output.db_connection_budget.source == "server-default" && length([
      for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment :
      entry if startswith(entry.name, "Limits__Connections__")
    ]) == 0
    error_message = "With an existing database and no db_max_connections_override the module must not guess."
  }
}

run "additional_env_wins_and_is_budgeted" {
  command = plan

  variables {
    additional_env = {
      Limits__Connections__MaxConnectionPoolSize = "50"
      Limits__Connections__MaxConcurrentQueries  = "50"
    }
  }

  # 1 x 2 x 50 = 100 > 79 usable.
  expect_failures = [output.db_connection_budget]
}

run "oversized_override_fails_plan" {
  command = plan

  variables {
    db_pool_size_override = 60
  }

  expect_failures = [output.db_connection_budget]
}

run "pooler_skips_the_check" {
  command = apply

  variables {
    db_pool_size_override        = 60
    db_connection_pooler_enabled = true
  }

  assert {
    condition = one([
      for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment :
      entry.value if entry.name == "Limits__Connections__MaxConnectionPoolSize"
    ]) == "60"
    error_message = "Behind a pooler the override must be rendered and not budget-checked."
  }
}

run "large_instance_is_clamped_to_the_server_default" {
  command = plan

  variables {
    db_instance_class = "db.r6g.4xlarge"
  }

  assert {
    condition     = output.db_connection_budget.max_connections == 5000 && output.db_connection_budget.pool_size == 200
    error_message = "The pool must not exceed the server default of 200."
  }
}
