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

run "default_has_no_static_issuer" {
  command = plan
  assert {
    condition     = length(local.oidc_static_environment) == 0 && length(local.oidc_signing_secret_arns) == 0 && length(local.oidc_signing_kms_arns) == 0
    error_message = "Defaults must add neither static issuer configuration nor signing-secret grants."
  }
}

run "typed_issuer_uses_exact_external_secret" {
  command = apply
  variables {
    oidc_static_jwt = {
      issuer                  = "https://fixture.example.test"
      audience                = "journey"
      signing_key_secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:journey-key-AbC123"
      signing_key_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    }
  }

  assert {
    condition = local.oidc_static_environment == tomap({
      Oidc__Enabled            = "true", Oidc__Generic__Enabled = "true",
      Oidc__Generic__Authority = "https://fixture.example.test", Oidc__Generic__ClientId = "journey"
    })
    error_message = "The complete typed issuer must render the exact canonical OIDC settings."
  }
  assert {
    condition     = local.lambda_environment.Oidc__TokenValidation__SymmetricSigningKey == "aws:secretsmanager:journey-key" && !contains(keys(local.control_plane_reconcile_environment), "Oidc__TokenValidation__SymmetricSigningKey")
    error_message = "Only the HTTP Lambda needs the secret reference; event handlers must not inherit the issuer."
  }
  assert {
    condition     = contains(jsondecode(aws_iam_policy.lambda_secrets.policy).Statement[0].Resource, var.oidc_static_jwt.signing_key_secret_arn) && !contains(local.lambda_secret_arns, var.oidc_static_jwt.signing_key_secret_arn) && length([for entry in jsondecode(aws_iam_policy.lambda_secrets.policy).Statement : entry if contains(entry.Resource, var.oidc_static_jwt.signing_key_kms_key_arn)]) == 1
    error_message = "Only the API runtime identity must receive the exact signing secret and KMS permissions."
  }
  assert {
    condition     = local.lambda_environment_bytes.api <= 4096
    error_message = "Opting into OIDC must preserve the real Lambda environment ceiling."
  }
}

run "reject_insecure_issuer" {
  command = plan
  variables {
    oidc_static_jwt = {
      issuer                  = "http://fixture.example.test"
      audience                = "journey"
      signing_key_secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:journey-key-AbC123"
      signing_key_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    }
  }
  expect_failures = [var.oidc_static_jwt]
}

run "reject_empty_audience" {
  command = plan
  variables {
    oidc_static_jwt = {
      issuer                  = "https://fixture.example.test"
      audience                = ""
      signing_key_secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:journey-key-AbC123"
      signing_key_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    }
  }
  expect_failures = [var.oidc_static_jwt]
}

run "reject_wildcard_secret" {
  command = plan
  variables {
    oidc_static_jwt = {
      issuer                  = "https://fixture.example.test"
      audience                = "journey"
      signing_key_secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:*"
      signing_key_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    }
  }
  expect_failures = [var.oidc_static_jwt]
}

run "reject_plaintext_key_override" {
  command = plan
  variables { additional_env = { Oidc__TokenValidation__SymmetricSigningKey = "test" } }
  expect_failures = [var.additional_env]
}

run "reject_conflicting_issuer" {
  command = plan
  variables {
    oidc_static_jwt = {
      issuer                  = "https://fixture.example.test"
      audience                = "journey"
      signing_key_secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:journey-key-AbC123"
      signing_key_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    }
    additional_env = { Oidc__Generic__Authority = "https://different.example.test" }
  }
  expect_failures = [terraform_data.oidc_static_jwt]
}

run "pins_the_consumed_secret_version" {
  command = plan
  variables {
    oidc_static_jwt = {
      issuer                        = "https://fixture.example.test"
      audience                      = "journey"
      signing_key_secret_arn        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:journey-key-AbC123"
      signing_key_secret_version_id = "11111111-2222-3333-4444-555555555555"
    }
  }
  assert {
    condition     = aws_lambda_function.this.environment[0].variables["Oidc__TokenValidation__SymmetricSigningKey"] == "aws:secretsmanager:journey-key?versionId=${var.oidc_static_jwt.signing_key_secret_version_id}"
    error_message = "Runtime must consume the immutable secret version selected by the caller."
  }
}

run "rejects_malformed_secret_version" {
  command = plan
  variables {
    oidc_static_jwt = {
      issuer                        = "https://fixture.example.test"
      audience                      = "journey"
      signing_key_secret_arn        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:journey-key-AbC123"
      signing_key_secret_version_id = "AWSCURRENT"
    }
  }
  expect_failures = [var.oidc_static_jwt]
}

run "preserves_full_arn_for_foreign_region" {
  command = plan
  variables {
    oidc_static_jwt = {
      issuer                        = "https://fixture.example.test"
      audience                      = "journey"
      signing_key_secret_arn        = "arn:aws:secretsmanager:us-west-2:123456789012:secret:journey-key-AbC123"
      signing_key_secret_version_id = "11111111-2222-3333-4444-555555555555"
    }
  }
  assert {
    condition     = aws_lambda_function.this.environment[0].variables["Oidc__TokenValidation__SymmetricSigningKey"] == "aws:secretsmanager:${var.oidc_static_jwt.signing_key_secret_arn}?versionId=${var.oidc_static_jwt.signing_key_secret_version_id}"
    error_message = "Only an unambiguous same-account and same-region secret name may be compacted; preserve the immutable version."
  }
}

run "preserves_full_arn_for_foreign_account" {
  command = plan
  variables {
    oidc_static_jwt = {
      issuer                        = "https://fixture.example.test"
      audience                      = "journey"
      signing_key_secret_arn        = "arn:aws:secretsmanager:us-east-1:999999999999:secret:journey-key-AbC123"
      signing_key_secret_version_id = "11111111-2222-3333-4444-555555555555"
    }
  }
  assert {
    condition     = aws_lambda_function.this.environment[0].variables["Oidc__TokenValidation__SymmetricSigningKey"] == "aws:secretsmanager:${var.oidc_static_jwt.signing_key_secret_arn}?versionId=${var.oidc_static_jwt.signing_key_secret_version_id}"
    error_message = "Only an unambiguous same-account and same-region secret name may be compacted; preserve the immutable version."
  }
}

run "preserves_full_arn_for_ambiguous_name" {
  command = plan
  variables {
    oidc_static_jwt = {
      issuer                        = "https://fixture.example.test"
      audience                      = "journey"
      signing_key_secret_arn        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:journey-key-123456-AbC123"
      signing_key_secret_version_id = "11111111-2222-3333-4444-555555555555"
    }
  }
  assert {
    condition     = aws_lambda_function.this.environment[0].variables["Oidc__TokenValidation__SymmetricSigningKey"] == "aws:secretsmanager:${var.oidc_static_jwt.signing_key_secret_arn}?versionId=${var.oidc_static_jwt.signing_key_secret_version_id}"
    error_message = "Only an unambiguous same-account and same-region secret name may be compacted; preserve the immutable version."
  }
}
