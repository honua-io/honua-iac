# Licensing contract for the 2026.1 candidate (honua-iac #191, honua-server #4721).
#
# The 2026.1 release ships with licensing DISABLED. The module must DECLARE
# Licensing__Mode=Disabled rather than leave the Lambda on the server's own
# default (Mode=Enabled), which with no license source resolves to the Community
# edition and gates editing/sync/streaming/geocoding; and with no envelope it
# must create no license secret and grant the execution role no access to one.
#
# The expected values are the server's published contract, not a snapshot of this
# module's output: Licensing:Mode parses only "Enabled" | "Disabled"
# (honua-server src/Honua.Hosting/Features/Licensing/LicenseOptions.cs), and the
# envelope is resolved from Licensing:LicenseContentSecretRef =
# aws:secretsmanager:<arn> at startup.

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
  image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server:v1.5.0"
  admin_password = "Synthetic-Terraform-Test-Admin-4721!aA1"

  # ElastiCache validates the auth token in-provider and the random provider is
  # mocked here, so supply one explicitly instead of auto-generating it.
  redis_auth_token = "SyntheticTerraformTestRedisToken1"
}

run "licensing_is_declared_disabled_by_default" {
  command = apply

  assert {
    condition     = local.licensing_mode == "Disabled"
    error_message = "The 2026.1 default must be licensing disabled, not the server's Enabled default."
  }

  # An exact value match, not a strcontains("Licensing__Mode") probe: the latter
  # would also pass on Licensing__Mode=Enabled.
  assert {
    condition     = local.lambda_environment["Licensing__Mode"] == "Disabled"
    error_message = "The Lambda environment must carry Licensing__Mode=Disabled."
  }

  assert {
    condition     = !contains(keys(local.lambda_environment), "Licensing__Edition")
    error_message = "A licensing-disabled deployment must not declare Licensing__Edition: an edition is only meaningful with a license."
  }

  assert {
    condition     = !contains(keys(local.lambda_environment), "Licensing__LicenseContentSecretRef")
    error_message = "A licensing-disabled deployment must not point the server at a license secret."
  }

  assert {
    condition = length([
      for key in keys(local.lambda_environment) : key if startswith(key, "Licensing__TrustedKeys__")
    ]) == 0
    error_message = "A licensing-disabled deployment must not publish a license verification key."
  }

  # "terraform plan shows no license secret when unset" (acceptance criterion).
  assert {
    condition     = length(aws_secretsmanager_secret.pro_license) == 0
    error_message = "No Secrets Manager license secret may be planned when no envelope is supplied."
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.pro_license) == 0
    error_message = "No license secret version may be planned when no envelope is supplied."
  }

  assert {
    condition     = local.pro_license_effective_secret_arn == null
    error_message = "No license secret ARN may be resolved when no envelope is supplied."
  }

  # "do not grant the execution role access to it" (acceptance criterion). The
  # grant is built with compact(), so a null ARN must drop the entry entirely
  # rather than widen the statement.
  assert {
    condition     = !strcontains(aws_iam_policy.lambda_secrets.policy, "license")
    error_message = "The Lambda execution role must be granted no access to a license secret when licensing is disabled."
  }
}

run "licensing_mode_travels_to_the_geoprocessing_batch_job" {
  command = apply

  variables {
    enable_gp_batch = true
  }

  # The GP container runs the same server image and evaluates the same
  # entitlement gates: a job definition left on the server default would refuse
  # geoprocessing on a deployment whose Lambda runs every feature.
  assert {
    condition = length([
      for entry in jsondecode(aws_batch_job_definition.gp["s"].container_properties).environment :
      entry if entry.name == "Licensing__Mode" && entry.value == "Disabled"
    ]) == 1
    error_message = "The geoprocessing Batch job definition must declare the same Licensing__Mode as the Lambda."
  }
}

run "an_explicit_enabled_mode_is_honoured_without_an_envelope" {
  command = apply

  variables {
    licensing_mode = "Enabled"
  }

  assert {
    condition     = local.lambda_environment["Licensing__Mode"] == "Enabled"
    error_message = "An operator who opts into licensing must get Licensing__Mode=Enabled."
  }

  assert {
    condition     = length(aws_secretsmanager_secret.pro_license) == 0
    error_message = "Enabling licensing without an envelope must still create no license secret."
  }
}

run "supplying_an_envelope_enables_licensing_and_scopes_access" {
  command = apply

  variables {
    licensing_mode                 = "Disabled"
    enable_gp_batch                = true
    enable_pro_license             = true
    pro_license_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-license-pro-AbCdEf"
    pro_license_key_id             = "honuademo2026q2"
    pro_license_trusted_public_key = "base64url:Y2XgDBncW5w6n7L3YG-T6HxX51DGybWazt0_gubk30k"
  }

  # An envelope is only meaningful to a server that loads and validates it, so
  # supplying one overrides the Disabled default rather than silently shipping a
  # license the server ignores.
  assert {
    condition     = local.licensing_mode == "Enabled" && local.lambda_environment["Licensing__Mode"] == "Enabled"
    error_message = "Supplying a license envelope must switch the declared mode to Enabled."
  }

  assert {
    condition     = local.lambda_environment["Licensing__LicenseContentSecretRef"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-license-pro-AbCdEf"
    error_message = "The adopted envelope must be referenced through Licensing__LicenseContentSecretRef."
  }

  assert {
    condition     = local.lambda_environment["Licensing__TrustedKeys__honuademo2026q2"] == "base64url:Y2XgDBncW5w6n7L3YG-T6HxX51DGybWazt0_gubk30k"
    error_message = "The verification key must be published under the relabeled, hyphen-free keyId."
  }

  # Adopt-by-ARN: Terraform learns the ARN and nothing else, so an apply can
  # neither read nor rewrite nor delete the envelope.
  assert {
    condition     = length(aws_secretsmanager_secret.pro_license) == 0 && length(aws_secretsmanager_secret_version.pro_license) == 0
    error_message = "Adopting an existing license secret must plan no secret and no secret version."
  }

  assert {
    condition     = strcontains(aws_iam_policy.lambda_secrets.policy, "honua-license-pro-AbCdEf")
    error_message = "The Lambda execution role must be granted read access to the adopted license secret."
  }

  assert {
    condition = length([
      for entry in jsondecode(aws_batch_job_definition.gp["s"].container_properties).environment :
      entry if entry.name == "Licensing__Mode" && entry.value == "Enabled"
    ]) == 1
    error_message = "The geoprocessing Batch job definition must follow the Lambda into Enabled mode."
  }
}

# Plan-only coverage for the two acceptance criteria that are about what a plan
# SHOWS. The runs above use command = apply against mocked providers so the
# rendered Lambda environment and IAM policy are concrete; these two assert on
# the plan itself, which is what an operator reviews before an apply.
run "plan_shows_no_license_secret_when_unset" {
  command = plan

  assert {
    condition     = length(aws_secretsmanager_secret.pro_license) == 0 && length(aws_secretsmanager_secret_version.pro_license) == 0
    error_message = "A plan with no license inputs must show no license secret and no license secret version."
  }

  assert {
    condition     = length(terraform_data.pro_license_validation) == 0
    error_message = "A plan with no license inputs must not even plan the license validation shim."
  }

  assert {
    condition     = local.pro_license_effective_secret_arn == null
    error_message = "No license secret ARN may be resolved when no envelope is supplied."
  }
}

run "plan_shows_the_license_path_still_works" {
  command = plan

  variables {
    enable_pro_license             = true
    pro_license_content            = "{\"keyId\":\"honuademo2026q2\",\"payload\":\"synthetic\",\"signature\":\"synthetic\"}"
    pro_license_key_id             = "honuademo2026q2"
    pro_license_trusted_public_key = "base64url:Y2XgDBncW5w6n7L3YG-T6HxX51DGybWazt0_gubk30k"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.pro_license) == 1 && length(aws_secretsmanager_secret_version.pro_license) == 1
    error_message = "The 2026.2 path must still plan a managed license secret and its version when the envelope is handed to Terraform."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.pro_license[0].secret_string == var.pro_license_content
    error_message = "The planned secret version must hold the supplied envelope verbatim."
  }

  assert {
    condition     = local.licensing_mode == "Enabled"
    error_message = "Supplying an envelope must switch the declared mode to Enabled."
  }
}

run "a_non_server_licensing_mode_is_rejected" {
  command = plan

  variables {
    licensing_mode = "Community"
  }

  expect_failures = [var.licensing_mode]
}
