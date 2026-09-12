# Licensing contract for the 2026.1 candidate (honua-iac #191, honua-server #4721).
#
# The 2026.1 release ships with licensing DISABLED: the module must DECLARE
# Licensing__Mode=Disabled rather than leave the server on its own default
# (Mode=Enabled), which with no license source resolves to the Community edition
# and gates editing/sync/streaming/geocoding.
#
# The expected values here are the server's published contract, not a snapshot of
# this module's output:
#   * Licensing:Mode parses only "Enabled" | "Disabled"
#     (honua-server src/Honua.Hosting/Features/Licensing/LicenseOptions.cs).
#   * Licensing:Edition is nullable; a null edition with no license source means
#     Community, so a licensing-disabled deployment must not declare an edition.
#   * A supplied envelope is delivered inline as Licensing:LicenseContent and
#     verified against Licensing:TrustedKeys:<keyId>.

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

run "licensing_is_declared_disabled_by_default" {
  command = apply

  assert {
    condition     = local.licensing_mode == "Disabled"
    error_message = "The 2026.1 default must be licensing disabled, not the server's Enabled default."
  }

  assert {
    condition     = output.licensing_mode == "Disabled"
    error_message = "The module must report the declared licensing mode so an operator can assert it without reading the task definition."
  }

  # The env pair is asserted as an exact {"name","value"} object in the rendered
  # task definition: a strcontains("Licensing__Mode") check would also pass on
  # Licensing__Mode=Enabled.
  assert {
    condition = length([
      for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment :
      entry if entry.name == "Licensing__Mode" && entry.value == "Disabled"
    ]) == 1
    error_message = "The primary task definition must carry exactly one Licensing__Mode=Disabled environment entry."
  }

  assert {
    condition = length([
      for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment :
      entry if entry.name == "Licensing__Edition"
    ]) == 0
    error_message = "A licensing-disabled deployment must not declare Licensing__Edition: an edition is only meaningful with a license."
  }

  assert {
    condition = length([
      for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment :
      entry if startswith(entry.name, "Licensing__TrustedKeys__")
    ]) == 0
    error_message = "A licensing-disabled deployment must not publish a license verification key."
  }

  assert {
    condition = length([
      for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets :
      entry if startswith(entry.name, "Licensing__")
    ]) == 0
    error_message = "A licensing-disabled deployment must inject no license secret into the task."
  }

  assert {
    condition     = output.pro_license_secret_arn == null
    error_message = "No license secret may be referenced when no envelope is supplied."
  }

  assert {
    condition     = !strcontains(aws_iam_policy.secrets.policy, "license")
    error_message = "The execution-role secrets policy must grant no access to a license secret when licensing is disabled."
  }
}

run "canary_task_shares_the_declared_licensing_mode" {
  command = apply

  variables {
    canary_enabled                  = true
    canary_desired_count            = 1
    canary_weight_percentage        = 10
    desired_count                   = 2
    max_capacity                    = 4
    deployment_mode                 = "MultiNode"
    redis_connection_string         = "redis.example.internal:6379,password=test,ssl=true"
    redis_connection_cidrs          = ["10.0.0.0/16"]
    file_storage_provider           = "AwsS3"
    file_storage_aws_s3_bucket_name = "honua-test-files"
  }

  # A canary running a different licensing mode than the primary would serve
  # different entitlements behind the same load balancer.
  assert {
    condition = length([
      for entry in jsondecode(aws_ecs_task_definition.canary[0].container_definitions)[0].environment :
      entry if entry.name == "Licensing__Mode" && entry.value == "Disabled"
    ]) == 1
    error_message = "The canary task definition must declare the same Licensing__Mode as the primary."
  }
}

run "licensing_mode_is_not_overridable_through_additional_env" {
  command = plan

  variables {
    additional_env = {
      "Licensing__Mode" = "Enabled"
    }
  }

  # Silently winning over additional_env would leave output.licensing_mode
  # disagreeing with the task definition, so the module refuses the input.
  expect_failures = [var.additional_env]
}

run "licensing_edition_is_not_overridable_through_canary_additional_env" {
  command = plan

  variables {
    canary_additional_env = {
      "Licensing:Edition" = "Enterprise"
    }
  }

  expect_failures = [var.canary_additional_env]
}

run "supplying_an_envelope_enables_licensing_and_scopes_access" {
  command = apply

  variables {
    pro_license_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-license-pro-AbCdEf"
    pro_license_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222"
    pro_license_key_id             = "honuademo2026q2"
    pro_license_trusted_public_key = "base64url:Y2XgDBncW5w6n7L3YG-T6HxX51DGybWazt0_gubk30k"
    licensing_edition              = "Enterprise"
  }

  assert {
    condition     = local.licensing_mode == "Enabled" && output.licensing_mode == "Enabled"
    error_message = "Supplying a license envelope must switch the declared mode to Enabled: an envelope is only meaningful to a server that loads it."
  }

  assert {
    condition = length([
      for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment :
      entry if entry.name == "Licensing__Edition" && entry.value == "Enterprise"
    ]) == 1
    error_message = "Licensing__Edition must be declared from licensing_edition when an envelope is supplied."
  }

  assert {
    condition = length([
      for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment :
      entry if entry.name == "Licensing__TrustedKeys__honuademo2026q2" && entry.value == "base64url:Y2XgDBncW5w6n7L3YG-T6HxX51DGybWazt0_gubk30k"
    ]) == 1
    error_message = "The verification key must be published under the relabeled, hyphen-free keyId."
  }

  assert {
    condition = length([
      for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets :
      entry if entry.name == "Licensing__LicenseContent" && entry.valueFrom == "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-license-pro-AbCdEf"
    ]) == 1
    error_message = "The envelope must be injected as an ECS Secrets Manager reference, never as a plaintext environment variable."
  }

  assert {
    condition     = strcontains(aws_iam_policy.secrets.policy, var.pro_license_secret_arn) && strcontains(aws_iam_policy.secrets.policy, var.pro_license_secret_kms_key_arn)
    error_message = "The execution-role policy must scope access to the supplied license secret and its customer-managed KMS key."
  }

  assert {
    condition     = output.pro_license_secret_arn == var.pro_license_secret_arn
    error_message = "The adopted license secret ARN must be reported back to the caller."
  }
}

run "an_envelope_without_its_verification_key_is_rejected" {
  command = plan

  variables {
    pro_license_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-license-pro-AbCdEf"
  }

  expect_failures = [aws_ecs_service.this]
}

run "a_non_server_licensing_mode_is_rejected" {
  command = plan

  variables {
    licensing_mode = "Community"
  }

  expect_failures = [var.licensing_mode]
}
