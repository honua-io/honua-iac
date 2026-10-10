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

  mock_data "aws_partition" {
    defaults = {
      dns_suffix         = "amazonaws.com"
      id                 = "aws"
      partition          = "aws"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:us-east-1:123456789012:repository/honua-server"
      registry_id    = "123456789012"
      repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
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

  mock_resource "aws_batch_compute_environment" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:123456789012:compute-environment/honua-mock"
    }
  }

  mock_resource "aws_batch_job_queue" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:123456789012:job-queue/honua-mock"
    }
  }

  mock_resource "aws_batch_job_definition" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:123456789012:job-definition/honua-mock:1"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:honua-mock:*"
    }
  }

  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      arn           = "arn:aws:apigateway:us-east-1::/apis/abcdefghij"
      execution_arn = "arn:aws:execute-api:us-east-1:123456789012:abcdefghij"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-mock-AbCdEf"
    }
  }
}

mock_provider "random" {}
mock_provider "null" {}

variables {
  # Recommended in Production; unset only plans with a check warning.
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"

  image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password = "Synthetic-Terraform-Test-Admin-4721!aA1"

  # ElastiCache validates the auth token in-provider and the random provider is
  # mocked here, so supply one explicitly instead of auto-generating it.
  redis_auth_token = "aaaaAAAA1111&&&&aaaaAAAA1111&&&&"

  # Redis is on by default, which requires the operator key-ring certificate.
  operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
}

run "no_allowlist_entry_is_rendered_by_default" {
  command = apply

  assert {
    condition     = length([for key in keys(local.lambda_environment) : key if startswith(key, "Security__RequestSecretReferences__")]) == 0
    error_message = "With no entries supplied the Lambda environment must carry no allowlist variable, preserving deny-by-default."
  }
}

run "entries_render_as_indexed_variables_in_list_order" {
  command = apply

  variables {
    request_secret_reference_allowed_environment_variables         = ["HONUA_IMPORT_ARCGIS_TOKEN"]
    request_secret_reference_allowed_environment_variable_prefixes = ["HONUA_IMPORT_"]
    request_secret_reference_allowed_secret_reference_prefixes     = ["aws:secretsmanager:honua/imports/", "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua/connections/"]
  }

  assert {
    condition = {
      for key, value in local.lambda_environment : key => value if startswith(key, "Security__RequestSecretReferences__")
      } == {
      Security__RequestSecretReferences__AllowedEnvironmentVariables__0        = "HONUA_IMPORT_ARCGIS_TOKEN"
      Security__RequestSecretReferences__AllowedEnvironmentVariablePrefixes__0 = "HONUA_IMPORT_"
      # checkov:skip=CKV_SECRET_6: Configuration key names and placeholder reference prefixes, not credentials.
      Security__RequestSecretReferences__AllowedSecretReferencePrefixes__0 = "aws:secretsmanager:honua/imports/"
      # checkov:skip=CKV_SECRET_6: Configuration key names and placeholder reference prefixes, not credentials.
      Security__RequestSecretReferences__AllowedSecretReferencePrefixes__1 = "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua/connections/"
    }
    error_message = "The Lambda environment must carry exactly the supplied entries under the server's indexed variable names."
  }
}

run "entries_travel_to_the_geoprocessing_batch_job" {
  command = apply

  variables {
    enable_gp_batch                                            = true
    request_secret_reference_allowed_secret_reference_prefixes = ["aws:secretsmanager:honua/imports/"]
  }

  # The GP container runs the same server image and resolves a secure
  # connection's stored reference under the same policy as the Lambda.
  assert {
    condition = length([
      for entry in jsondecode(aws_batch_job_definition.gp["s"].container_properties).environment :
      entry if entry.name == "Security__RequestSecretReferences__AllowedSecretReferencePrefixes__0" && entry.value == "aws:secretsmanager:honua/imports/"
    ]) == 1
    error_message = "The geoprocessing Batch job definition must carry the same allowlist entries as the Lambda."
  }
}

run "the_geoprocessing_batch_job_carries_no_entry_by_default" {
  command = apply

  variables {
    enable_gp_batch = true
  }

  assert {
    condition = length([
      for entry in jsondecode(aws_batch_job_definition.gp["s"].container_properties).environment :
      entry if startswith(entry.name, "Security__RequestSecretReferences__")
    ]) == 0
    error_message = "With no entries supplied the geoprocessing Batch job definition must carry no allowlist variable."
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

# The allowlist only decides what the server may try to resolve; the Lambda and
# the geoprocessing job read an allowed aws:secretsmanager: reference with their
# own roles, so both need the grant, and nothing is granted by default.
run "no_request_secret_grant_by_default" {
  command = apply

  variables {
    enable_gp_batch = true
  }

  assert {
    condition     = length(aws_iam_role_policy.lambda_request_secret_references) == 0 && length(aws_iam_role_policy.batch_job_request_secret_references) == 0
    error_message = "With no secret ARNs supplied neither runtime role may receive an additional secret grant."
  }
}

run "allowlisted_secrets_are_granted_to_the_lambda_and_batch_roles" {
  command = apply

  variables {
    enable_gp_batch                                            = true
    request_secret_reference_allowed_secret_reference_prefixes = ["aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua/imports/"]
    request_secret_reference_secret_arns                       = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:honua/imports/*"]
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.lambda_request_secret_references[0].policy).Statement == [{ Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:honua/imports/*"] }]
    error_message = "The Lambda role must be granted read-only access to exactly the supplied secret ARNs, and no KMS grant when no key is supplied."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.batch_job_request_secret_references[0].policy).Statement == jsondecode(aws_iam_role_policy.lambda_request_secret_references[0].policy).Statement
    error_message = "The geoprocessing job role must carry the same grant as the Lambda role."
  }
}

run "allowlisted_environment_values_travel_to_the_geoprocessing_batch_job" {
  command = apply

  variables {
    enable_gp_batch                                                = true
    request_secret_reference_allowed_environment_variables         = ["IMPORT_TOKEN_EXACT"]
    request_secret_reference_allowed_environment_variable_prefixes = ["HONUA_IMPORT_"]
    additional_env = {
      # checkov:skip=CKV_SECRET_6: Synthetic environment names and placeholder values, not credentials.
      IMPORT_TOKEN_EXACT        = "exact-value"
      HONUA_IMPORT_ARCGIS       = "prefixed-value"
      HONUA_IMPORT_Section__Key = "binds-configuration"
      UNRELATED_SETTING         = "not-allowlisted"
    }
  }

  # Mirrors the server rule: an exact name, or a prefix match on a name without "__".
  assert {
    condition = {
      for entry in jsondecode(aws_batch_job_definition.gp["s"].container_properties).environment :
      entry.name => entry.value if contains(["IMPORT_TOKEN_EXACT", "HONUA_IMPORT_ARCGIS", "HONUA_IMPORT_Section__Key", "UNRELATED_SETTING"], entry.name)
      } == {
      IMPORT_TOKEN_EXACT  = "exact-value"
      HONUA_IMPORT_ARCGIS = "prefixed-value"
    }
    error_message = "The geoprocessing job must receive exactly the additional_env values the environment allowlist permits."
  }
}

# Browser origins (honua-server cloud-deployments guide: Cors__AllowedOrigins__0
# is required for Console/Studio). Nothing by default (no server variable and no
# API Gateway CORS); supplied origins render as indexed variables in list order.
run "no_cors_origin_is_rendered_by_default" {
  command = plan

  assert {
    condition     = length([for key in keys(local.lambda_environment) : key if startswith(key, "Cors__")]) == 0 && length(aws_apigatewayv2_api.this.cors_configuration) == 0
    error_message = "API-only cells need no CORS; neither the server variable nor API Gateway CORS may be configured by default."
  }
}

run "cors_origins_render_as_indexed_variables" {
  command = plan

  variables {
    cors_allowed_origins = ["https://console.example.com", "https://studio.example.com"]
  }

  assert {
    condition = {
      for key, value in local.lambda_environment : key => value if startswith(key, "Cors__")
      } == {
      Cors__AllowedOrigins__0 = "https://console.example.com"
      Cors__AllowedOrigins__1 = "https://studio.example.com"
    }
    error_message = "The Lambda must carry the origins as Cors__AllowedOrigins__<n> in list order."
  }

  assert {
    condition     = toset(aws_apigatewayv2_api.this.cors_configuration[0].allow_origins) == toset(["https://console.example.com", "https://studio.example.com"])
    error_message = "API Gateway CORS must admit the same origins."
  }
}
