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
  image                            = "ghcr.io/honua-io/honua-server:v1.5.0"
  admin_password                   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  connection_encryption_master_key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  existing_vpc_id             = "vpc-0123456789abcdef0"
  existing_vpc_cidr           = "10.0.0.0/16"
  existing_public_subnet_ids  = ["subnet-00000000000000001", "subnet-00000000000000002"]
  existing_private_subnet_ids = ["subnet-00000000000000003", "subnet-00000000000000004"]

  existing_db_endpoint          = "postgres.example.internal"
  existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"

  redis_enabled           = false
  kms_key_arn             = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
  alb_access_logs_enabled = false
}

run "single_instance_default_is_safe" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret_version.master_key.secret_string == var.connection_encryption_master_key
    error_message = "The connection encryption secret must contain the independent master key."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.master_key.secret_string != aws_secretsmanager_secret_version.admin_password.secret_string
    error_message = "The connection encryption key must not alias the admin password."
  }
}

run "ai_provider_secret_uses_reference_and_scoped_kms" {
  command = apply

  variables {
    ai_provider_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-ai-provider"
    ai_provider_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
  }

  assert {
    condition     = strcontains(aws_ecs_task_definition.this.container_definitions, "HONUA_AI_PROVIDER_API_KEY") && strcontains(aws_ecs_task_definition.this.container_definitions, var.ai_provider_secret_arn)
    error_message = "The AI provider credential must be emitted as an ECS Secrets Manager reference."
  }

  assert {
    condition     = strcontains(aws_iam_policy.secrets.policy, var.ai_provider_secret_arn) && strcontains(aws_iam_policy.secrets.policy, var.ai_provider_secret_kms_key_arn)
    error_message = "The execution-role policy must scope access to the supplied secret and customer-managed KMS key ARN."
  }
}

run "ai_provider_secret_omits_optional_access_when_unconfigured" {
  command = apply

  assert {
    condition     = !strcontains(aws_ecs_task_definition.this.container_definitions, "HONUA_AI_PROVIDER_API_KEY")
    error_message = "An omitted AI provider secret must not add an ECS secret mapping."
  }
}

run "connection_encryption_key_is_generated_when_unset" {
  command = plan

  variables {
    connection_encryption_master_key = null
  }

  assert {
    condition     = length(random_password.master_key) == 1
    error_message = "An independent connection encryption key must be generated when no key is provided."
  }
}

run "reserved_runtime_env_cannot_bypass_typed_inputs" {
  command = plan

  variables {
    additional_env = {
      "deployment:mode" = "MultiNode"
    }
  }

  expect_failures = [var.additional_env]
}

run "invalid_elasticache_auth_token_is_rejected" {
  command = plan

  variables {
    redis_auth_token = "aaaaaaaaaaaaaaaa"
  }

  expect_failures = [var.redis_auth_token]
}

run "single_instance_scale_out_is_rejected" {
  command = plan

  variables {
    desired_count = 2
    max_capacity  = 2
  }

  expect_failures = [aws_ecs_service.this]
}

run "multinode_without_shared_dependencies_is_rejected" {
  command = plan

  variables {
    deployment_mode = "MultiNode"
  }

  expect_failures = [aws_ecs_service.this]
}

run "multinode_scale_out_with_redis_and_s3_is_safe" {
  command = plan

  variables {
    desired_count                   = 2
    max_capacity                    = 4
    deployment_mode                 = "MultiNode"
    redis_connection_string         = "redis.example.internal:6379,password=test,ssl=true"
    redis_connection_cidrs          = ["10.0.0.0/16"]
    file_storage_provider           = "AwsS3"
    file_storage_aws_s3_bucket_name = "honua-test-files"
  }
}
