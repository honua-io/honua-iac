# Import background-job threshold (import_background_job_threshold_bytes).
#
# honua-server hands an upload larger than Import:Limits:BackgroundJobThresholdBytes
# (default 100 MiB) to a background job instead of importing it inline. The
# release harness lowers it on Redis-on cells (honua-release#548, S10
# large-import). The module renders the key only when the input is set, on
# the primary and canary containers; null keeps the server default.

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
  # Recommended in Production; unset only plans with a check warning.
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"

  image                            = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
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

run "null_by_default_renders_nothing" {
  command = plan

  assert {
    condition     = var.import_background_job_threshold_bytes == null && length([for e in concat(local.primary_container_environment, local.canary_container_environment) : e if e.name == "Import__Limits__BackgroundJobThresholdBytes"]) == 0
    error_message = "With import_background_job_threshold_bytes null the containers must not carry Import__Limits__BackgroundJobThresholdBytes."
  }

  assert {
    condition     = output.import_background_job_threshold_bytes_rendered.primary == null && output.import_background_job_threshold_bytes_rendered.canary == null
    error_message = "The rendered-threshold output must be null for both slots when the input is null."
  }
}

run "set_renders_on_primary_and_canary" {
  command = plan

  variables {
    import_background_job_threshold_bytes = 67108864
    # A canary runs a second task, which needs the multi-node topology.
    canary_enabled                            = true
    deployment_mode                           = "MultiNode"
    file_storage_provider                     = "AwsS3"
    file_storage_aws_s3_bucket_name           = "honua-test-files"
    redis_enabled                             = true
    redis_auth_token                          = "aA1aaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  }

  assert {
    condition = alltrue([
      for environment in [local.primary_container_environment, local.canary_container_environment] :
      one([for e in environment : e.value if e.name == "Import__Limits__BackgroundJobThresholdBytes"]) == "67108864"
    ])
    error_message = "import_background_job_threshold_bytes = 67108864 must render Import__Limits__BackgroundJobThresholdBytes=67108864 on the primary and canary containers."
  }

  assert {
    condition     = output.import_background_job_threshold_bytes_rendered == { primary = "67108864", canary = "67108864" }
    error_message = "The rendered-threshold output must report the value for both slots."
  }
}

run "typed_input_wins_over_additional_env" {
  command = plan

  variables {
    import_background_job_threshold_bytes = 67108864
    additional_env = {
      Import__Limits__BackgroundJobThresholdBytes = "1"
    }
  }

  assert {
    condition     = one([for e in local.primary_container_environment : e.value if e.name == "Import__Limits__BackgroundJobThresholdBytes"]) == "67108864"
    error_message = "The typed input must win over the same key in additional_env, and render once."
  }
}

run "reject_zero" {
  command = plan

  variables {
    import_background_job_threshold_bytes = 0
  }

  expect_failures = [var.import_background_job_threshold_bytes]
}

run "reject_negative" {
  command = plan

  variables {
    import_background_job_threshold_bytes = -1
  }

  expect_failures = [var.import_background_job_threshold_bytes]
}

run "reject_fraction" {
  command = plan

  variables {
    import_background_job_threshold_bytes = 1.5
  }

  expect_failures = [var.import_background_job_threshold_bytes]
}
