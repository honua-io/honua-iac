# Allowlist for request-supplied secret references (honua-server #5055).
#
# The server section Security:RequestSecretReferences is deny-by-default, so the
# module must render NOTHING unless an operator supplies entries, and must render
# supplied entries as indexed variables in list order. The expected names are the
# server's published contract (docs/guides/deploy/configuration.md), not a
# snapshot of this module's output.

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

run "no_allowlist_entry_is_rendered_by_default" {
  command = plan

  assert {
    condition     = length([for key in keys(local.runtime_environment) : key if startswith(key, "Security__RequestSecretReferences__")]) == 0
    error_message = "With no entries supplied the container environment must carry no allowlist variable, preserving deny-by-default."
  }
}

run "entries_render_as_indexed_variables_in_list_order" {
  command = plan

  variables {
    request_secret_reference_allowed_environment_variables         = ["HONUA_IMPORT_ARCGIS_TOKEN"]
    request_secret_reference_allowed_environment_variable_prefixes = ["HONUA_IMPORT_"]
    request_secret_reference_allowed_secret_reference_prefixes     = ["aws:secretsmanager:honua/imports/", "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua/connections/"]
  }

  assert {
    condition = {
      for entry in local.primary_container_environment : entry.name => entry.value if startswith(entry.name, "Security__RequestSecretReferences__")
      } == {
      Security__RequestSecretReferences__AllowedEnvironmentVariables__0        = "HONUA_IMPORT_ARCGIS_TOKEN"
      Security__RequestSecretReferences__AllowedEnvironmentVariablePrefixes__0 = "HONUA_IMPORT_"
      # checkov:skip=CKV_SECRET_6: Configuration key names and placeholder reference prefixes, not credentials.
      Security__RequestSecretReferences__AllowedSecretReferencePrefixes__0 = "aws:secretsmanager:honua/imports/"
      # checkov:skip=CKV_SECRET_6: Configuration key names and placeholder reference prefixes, not credentials.
      Security__RequestSecretReferences__AllowedSecretReferencePrefixes__1 = "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua/connections/"
    }
    error_message = "The primary container must carry exactly the supplied entries under the server's indexed variable names."
  }

  assert {
    condition = {
      for entry in local.canary_container_environment : entry.name => entry.value if startswith(entry.name, "Security__RequestSecretReferences__")
      } == {
      Security__RequestSecretReferences__AllowedEnvironmentVariables__0        = "HONUA_IMPORT_ARCGIS_TOKEN"
      Security__RequestSecretReferences__AllowedEnvironmentVariablePrefixes__0 = "HONUA_IMPORT_"
      # checkov:skip=CKV_SECRET_6: Configuration key names and placeholder reference prefixes, not credentials.
      Security__RequestSecretReferences__AllowedSecretReferencePrefixes__0 = "aws:secretsmanager:honua/imports/"
      # checkov:skip=CKV_SECRET_6: Configuration key names and placeholder reference prefixes, not credentials.
      Security__RequestSecretReferences__AllowedSecretReferencePrefixes__1 = "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua/connections/"
    }
    error_message = "The canary container runs the same server and must carry the same entries."
  }
}

run "an_environment_reference_is_rejected_as_a_whole_reference_prefix" {
  command = plan

  variables {
    request_secret_reference_allowed_secret_reference_prefixes = ["env:HONUA_ADMIN_PASSWORD"]
  }

  expect_failures = [var.request_secret_reference_allowed_secret_reference_prefixes]
}

run "a_prefix_without_a_provider_segment_is_rejected" {
  command = plan

  variables {
    request_secret_reference_allowed_secret_reference_prefixes = ["honua/imports/"]
  }

  expect_failures = [var.request_secret_reference_allowed_secret_reference_prefixes]
}

run "an_invalid_environment_variable_name_is_rejected" {
  command = plan

  variables {
    request_secret_reference_allowed_environment_variables = ["NOT-A-NAME"]
  }

  expect_failures = [var.request_secret_reference_allowed_environment_variables]
}

run "an_invalid_environment_variable_prefix_is_rejected" {
  command = plan

  variables {
    request_secret_reference_allowed_environment_variable_prefixes = ["env:HONUA_"]
  }

  expect_failures = [var.request_secret_reference_allowed_environment_variable_prefixes]
}

# The allowlist only decides what the server may try to resolve; the server
# reads an allowed aws:secretsmanager: reference with the TASK role, so the
# grant must land there, and nothing is granted by default.
run "no_request_secret_grant_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.task_request_secret_references) == 0
    error_message = "With no secret ARNs supplied the task role must receive no additional secret grant."
  }
}

run "allowlisted_secrets_are_granted_to_the_task_role" {
  command = plan

  variables {
    request_secret_reference_allowed_secret_reference_prefixes = ["aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua/imports/"]
    request_secret_reference_secret_arns                       = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:honua/imports/*"]
    request_secret_reference_kms_key_arns                      = ["arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002"]
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.task_request_secret_references[0].policy).Statement[0].Resource == ["arn:aws:secretsmanager:us-east-1:123456789012:secret:honua/imports/*"]
    error_message = "The task role must be granted GetSecretValue on exactly the supplied secret ARNs."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.task_request_secret_references[0].policy).Statement[0].Action == ["secretsmanager:GetSecretValue"]
    error_message = "The request secret grant must be read-only."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.task_request_secret_references[0].policy).Statement[1].Resource == ["arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002"]
    error_message = "The task role must be granted kms:Decrypt on exactly the supplied keys."
  }
}

run "a_secret_arn_with_an_open_account_is_rejected" {
  command = plan

  variables {
    request_secret_reference_secret_arns = ["arn:aws:secretsmanager:*:*:secret:*"]
  }

  expect_failures = [var.request_secret_reference_secret_arns]
}

# Browser origins (honua-server cloud-deployments guide: Cors__AllowedOrigins__0
# is required for Console/Studio). Nothing by default; supplied origins render
# as indexed variables in list order on the primary and the canary.
run "no_cors_origin_is_rendered_by_default" {
  command = plan

  assert {
    condition     = length([for entry in local.primary_container_environment : entry.name if startswith(entry.name, "Cors__")]) == 0
    error_message = "API-only cells need no CORS origin; none may be rendered by default."
  }
}

run "cors_origins_render_as_indexed_variables" {
  command = plan

  variables {
    cors_allowed_origins = ["https://console.example.com", "https://studio.example.com"]
  }

  assert {
    condition = {
      for entry in local.primary_container_environment : entry.name => entry.value if startswith(entry.name, "Cors__")
      } == {
      Cors__AllowedOrigins__0 = "https://console.example.com"
      Cors__AllowedOrigins__1 = "https://studio.example.com"
    }
    error_message = "The primary container must carry the origins as Cors__AllowedOrigins__<n> in list order."
  }

  assert {
    condition = {
      for entry in local.canary_container_environment : entry.name => entry.value if startswith(entry.name, "Cors__")
      } == {
      Cors__AllowedOrigins__0 = "https://console.example.com"
      Cors__AllowedOrigins__1 = "https://studio.example.com"
    }
    error_message = "The canary container must carry the same origins."
  }
}
