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

  mock_resource "aws_s3_bucket" {
    defaults = {
      id  = "honua-test-alb-logs"
      arn = "arn:aws:s3:::honua-test-alb-logs"
    }
  }
}

mock_provider "random" {}
mock_provider "null" {}

variables {
  operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-hardening.tftest-AbC123"
  audit_chain_key_secret_arn                = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"

  image                            = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password                   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  connection_encryption_master_key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  existing_vpc_id             = "vpc-0123456789abcdef0"
  existing_vpc_cidr           = "10.0.0.0/16"
  existing_public_subnet_ids  = ["subnet-00000000000000001", "subnet-00000000000000002"]
  existing_private_subnet_ids = ["subnet-00000000000000003", "subnet-00000000000000004"]

  existing_db_endpoint          = "postgres.example.internal"
  existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"

  kms_key_arn             = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
  alb_access_logs_enabled = true
}

run "primary_canary_and_alb_logs_hardening" {
  command = apply

  variables {
    deployment_mode                 = "MultiNode"
    file_storage_provider           = "AwsS3"
    file_storage_aws_s3_bucket_name = "honua-shared-files"
    canary_enabled                  = true
    canary_image                    = "ghcr.io/honua-io/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    migration_task                  = true
  }

  assert {
    condition     = aws_lb_target_group.this.deregistration_delay == "30" && aws_lb_target_group.canary[0].deregistration_delay == "30"
    error_message = "Primary and canary target groups must set deregistration_delay = 30."
  }

  assert {
    condition     = aws_ecs_service.this.health_check_grace_period_seconds == 180 && aws_ecs_service.canary[0].health_check_grace_period_seconds == 180
    error_message = "Primary and canary ECS services must set health_check_grace_period_seconds = 180."
  }

  assert {
    condition = alltrue([
      for definition in [
        aws_ecs_task_definition.this.container_definitions,
        aws_ecs_task_definition.canary[0].container_definitions,
        aws_ecs_task_definition.migrate[0].container_definitions
        ] : (
        jsondecode(definition)[0].user == "1001:1001" &&
        jsondecode(definition)[0].stopTimeout == 120 &&
        jsondecode(definition)[0].linuxParameters.initProcessEnabled == true &&
        jsondecode(definition)[0].linuxParameters.capabilities.drop == ["ALL"] &&
        one([for e in jsondecode(definition)[0].environment : e.value if e.name == "HostOptions__ShutdownTimeout"]) == "00:01:30"
      )
    ])
    error_message = "Primary, canary, and migrate task definitions must enforce non-root user 1001:1001, drop ALL capabilities, initProcessEnabled, stopTimeout=120, and HostOptions__ShutdownTimeout=00:01:30."
  }

  assert {
    condition = (
      anytrue([
        for s in jsondecode(aws_s3_bucket_policy.alb_logs[0].policy).Statement :
        s.Sid == "DenyInsecureTransport" && s.Effect == "Deny" && s.Condition.Bool["aws:SecureTransport"] == "false"
      ]) &&
      length([
        for s in jsondecode(aws_s3_bucket_policy.alb_logs[0].policy).Statement : s
        if try(s.Principal.Service, "") == "logdelivery.elasticloadbalancing.amazonaws.com" &&
        try(s.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
      ]) == 2
    )
    error_message = "ALB access logs bucket policy must deny insecure transport and scope logdelivery service statements to aws:SourceAccount."
  }
}
