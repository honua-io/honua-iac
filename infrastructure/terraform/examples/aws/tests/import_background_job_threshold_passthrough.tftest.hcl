# Import background-job threshold (import_background_job_threshold_bytes).
#
# The release harness passes import_background_job_threshold_bytes=67108864 on
# the Redis-on cells when the root declares it (honua-release#548, S10
# large-import), so an upload between 64 MiB and the 100 MiB staging cap runs
# as a background import. The root passes it to the module, which renders
# Import__Limits__BackgroundJobThresholdBytes on every server process; null
# (default) renders nothing and keeps the server default (100 MiB).
# Mocked providers; plan only; no credentials, no AWS calls.

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
  # A reachable cell: without an ingress list or certificate the root's
  # alb_reachable_from_outside_vpc check fails, which terraform test reports
  # as a failed run. 203.0.113.0/24 is TEST-NET-3 (RFC 5737).
  allow_http_ingress_cidrs = ["203.0.113.10/32"]

  operation_key_ring_certificate_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002"
  operation_key_ring_certificate_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  audit_chain_key_secret_arn                        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
  honua_image                                       = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  honua_admin_password                              = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  honua_connection_encryption_master_key            = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

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

run "null_by_default_renders_nothing" {
  command = plan

  assert {
    condition     = var.import_background_job_threshold_bytes == null && module.honua.import_background_job_threshold_bytes_rendered == { primary = null, canary = null }
    error_message = "import_background_job_threshold_bytes must default to null and render nothing on the primary or canary task definition."
  }
}

run "threshold_renders_on_primary_and_canary" {
  command = plan

  variables {
    import_background_job_threshold_bytes = 67108864
  }

  assert {
    condition     = module.honua.import_background_job_threshold_bytes_rendered == { primary = "67108864", canary = "67108864" }
    error_message = "import_background_job_threshold_bytes = 67108864 must render Import__Limits__BackgroundJobThresholdBytes=67108864 on the primary and canary task definitions."
  }
}

run "zero_threshold_is_rejected" {
  command = plan

  variables {
    import_background_job_threshold_bytes = 0
  }

  expect_failures = [var.import_background_job_threshold_bytes]
}
