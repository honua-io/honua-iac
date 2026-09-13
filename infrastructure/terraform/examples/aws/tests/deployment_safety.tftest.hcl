mock_provider "aws" {
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-east-1:123456789012:cluster/honuaecs-it-cluster" }
  }

  mock_data "aws_iam_role" {
    defaults = {
      name = "retained-controller"
      arn  = "arn:aws:iam::123456789012:role/retained-controller"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-123456" }
  }
  mock_resource "aws_lb_listener_rule" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener-rule/app/honua-test/0000000000000000/1111111111111111/2222222222222222"
    }
  }

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
  honua_image                            = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  honua_admin_password                   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  honua_connection_encryption_master_key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  existing_vpc_id             = "vpc-0123456789abcdef0"
  existing_vpc_cidr           = "10.0.0.0/16"
  existing_public_subnet_ids  = ["subnet-00000000000000001", "subnet-00000000000000002"]
  existing_private_subnet_ids = ["subnet-00000000000000003", "subnet-00000000000000004"]

  existing_db_endpoint          = "postgres.example.internal"
  existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"

  redis_enabled           = false
  alb_access_logs_enabled = false

  deployment_mode                 = "MultiNode"
  desired_count                   = 2
  max_capacity                    = 2
  redis_connection_string         = "redis.example.internal:6379,password=test,ssl=true"
  redis_connection_cidrs          = ["10.0.0.0/16"]
  file_storage_provider           = "AwsS3"
  file_storage_aws_s3_bucket_name = "honua-test-files"
  canary_enabled                  = true
  canary_desired_count            = 1
  deployment_safety = {
    controller_role_name    = "retained-controller"
    telemetry_connection_id = "cert-prometheus"
    prometheus_canary_job   = "cert-cell-canary"
    functional_probe_url    = "https://candidate.example.com/fixture"
    # SHA-256 of the independently specified golden response bytes: abc
    functional_expected_sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  }
}

run "native_profile_is_projected_without_live_claims" {
  command = apply
  assert {
    condition = (
      output.operations_contract.resilience.protection_profile.execution.backend_name == "honua-aws-ecs-alb" &&
      output.deployment_contract.rollout.backend_name == "honua-aws-ecs-alb" &&
      output.deployment_contract.rollout.target_id == output.operations_contract.resilience.protection_profile.execution.target_id &&
      output.operations_contract.resilience.protection_profile.qualification == "unverified" &&
      output.operations_contract.resilience.protection_profile.durable_state.cache_enabled &&
      output.deployment_contract.dependencies.cache.enabled &&
      !output.deployment_contract.dependencies.database.managed &&
      output.operations_contract.resilience.protection_profile.health_sources.functional_check_path == null &&
      output.operations_contract.resilience.protection_profile.recovery.recovery_time_bound_seconds == null
    )
    error_message = "The installed contract must match the native target and external Redis while keeping readiness, provider startup protection and live recovery qualification distinct."
  }
}
run "default_single_instance_has_no_bounded_outage_claim" {
  command = apply
  variables {
    deployment_safety = null
    deployment_mode   = "SingleInstance"
    canary_enabled    = false
    desired_count     = 1
    max_capacity      = 1
  }
  assert {
    condition = (
      output.operations_contract.resilience.protection_profile.availability_class == "single-task" &&
      output.operations_contract.resilience.protection_profile.interruption_guarantee == "interruption-until-replacement-ready" &&
      output.operations_contract.resilience.protection_profile.execution == null &&
      output.operations_contract.resilience.protection_profile.recovery.requires_prior_completed_deployment
    )
    error_message = "A single-instance deployment must not imply a brief or zero-downtime outage or configured post-activation execution."
  }
}
run "multinode_one_task_does_not_claim_redundancy" {
  command = apply
  variables {
    deployment_safety = null
    canary_enabled    = false
    desired_count     = 1
    max_capacity      = 4
  }
  assert {
    condition = (
      output.operations_contract.resilience.protection_profile.availability_class == "single-task" &&
      output.operations_contract.resilience.protection_profile.interruption_guarantee == "rolling-through-healthy-tasks"
    )
    error_message = "An autoscaling ceiling and shared storage permit surge but do not imply multiple baseline tasks."
  }
}

override_resource {
  target = module.honua.aws_lb_target_group.canary[0]
  values = {
    arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/honua-canary/2222222222222222"
  }
}
