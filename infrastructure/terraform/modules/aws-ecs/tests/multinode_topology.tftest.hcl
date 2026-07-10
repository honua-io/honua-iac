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
}

mock_provider "random" {}
mock_provider "null" {}

variables {
  image          = "ghcr.io/honua-io/honua-server:v1.5.0"
  admin_password = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

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
