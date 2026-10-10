# Redis operation key-ring certificate on Lambda (honua-iac#213 follow-up).
#
# A connected Redis makes the server compose the durable operation secret
# channel, which refuses to start without the key-ring certificate. Lambda
# cannot resolve Secrets Manager into env, so the module must hand the function
# an aws:secretsmanager: REFERENCE (never the value), grant the function roles
# read on exactly that secret, fail planning when Redis is on without it, and
# leave Redis-off cells with no certificate dependency.

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

  # Control-plane event targets and schedules validate these ARNs in-provider.
  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:123456789012:function:honua-mock"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-1:123456789012:rule/honua-mock"
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
}

run "redis_on_requires_operation_certificate" {
  command = plan

  variables {
    redis_enabled = true
  }

  expect_failures = [aws_lambda_function.this]
}

run "external_redis_also_requires_operation_certificate" {
  command = plan

  variables {
    redis_enabled           = false
    redis_connection_string = "redis.example.internal:6379,password=test,ssl=true"
    redis_connection_cidrs  = ["10.0.0.0/16"]
  }

  expect_failures = [aws_lambda_function.this]
}

run "redis_on_passes_only_a_secret_reference" {
  command = apply

  variables {
    redis_enabled                             = true
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  }

  assert {
    condition     = aws_lambda_function.this.environment[0].variables["Operations__SecretChannel__KeyRingCertificatePkcs12"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    error_message = "The Lambda must carry the key-ring certificate as an aws:secretsmanager: reference the server resolves with the function role."
  }

  assert {
    condition = length([
      for key in keys(aws_lambda_function.this.environment[0].variables) : key
      if startswith(lower(key), "operations__secretchannel__") && key != "Operations__SecretChannel__KeyRingCertificatePkcs12"
    ]) == 0
    error_message = "Only the PKCS#12 reference may be set; a path or password would bypass the protected bundle."
  }

  assert {
    condition = contains(
      flatten([for statement in jsondecode(aws_iam_policy.lambda_secrets.policy).Statement : statement.Resource if contains(statement.Action, "secretsmanager:GetSecretValue")]),
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    )
    error_message = "The function role must be able to read exactly the operator's certificate secret."
  }

  assert {
    condition     = length([for statement in jsondecode(aws_iam_policy.lambda_secrets.policy).Statement : statement if contains(statement.Action, "kms:Decrypt")]) == 0
    error_message = "Without a customer-managed key the function role gets no KMS grant."
  }
}

run "customer_managed_key_is_granted_exactly" {
  command = apply

  variables {
    redis_enabled                                     = true
    operation_key_ring_certificate_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    operation_key_ring_certificate_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002"
  }

  assert {
    condition = [
      for statement in jsondecode(aws_iam_policy.lambda_secrets.policy).Statement : statement.Resource if contains(statement.Action, "kms:Decrypt")
    ] == [["arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002"]]
    error_message = "A customer-managed key must be granted kms:Decrypt on exactly that key."
  }
}

run "control_plane_event_functions_can_read_the_certificate" {
  command = apply

  variables {
    redis_enabled                             = true
    enable_control_plane_events               = true
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  }

  # The event functions share the API host's environment, so they carry the same
  # reference and need the same read grant.
  assert {
    condition     = aws_lambda_function.control_plane_reconcile[0].environment[0].variables["Operations__SecretChannel__KeyRingCertificatePkcs12"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    error_message = "The reconcile function must carry the same certificate reference as the API function."
  }

  assert {
    condition = contains(
      one([for statement in jsondecode(aws_iam_role_policy.control_plane_events[0].policy).Statement : statement.Resource if statement.Sid == "ReadHonuaSecrets"]),
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    )
    error_message = "The control-plane event role must be able to read the certificate secret."
  }
}

run "redis_off_has_no_certificate_dependency" {
  command = apply

  variables {
    redis_enabled                             = false
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  }

  assert {
    condition     = !contains(keys(aws_lambda_function.this.environment[0].variables), "Operations__SecretChannel__KeyRingCertificatePkcs12")
    error_message = "Redis-off must not request operation certificate material."
  }

  assert {
    condition = !contains(
      flatten([for statement in jsondecode(aws_iam_policy.lambda_secrets.policy).Statement : statement.Resource]),
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    )
    error_message = "Redis-off must not grant read on the unused certificate secret."
  }
}

run "redis_off_plans_without_a_certificate" {
  command = plan

  variables {
    redis_enabled = false
  }
}

run "reject_plain_certificate_input" {
  command = plan

  variables {
    operation_key_ring_certificate_secret_arn = "YWFh"
  }

  expect_failures = [var.operation_key_ring_certificate_secret_arn]
}

run "reject_certificate_wildcard" {
  command = plan

  variables {
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-*"
  }

  expect_failures = [var.operation_key_ring_certificate_secret_arn]
}

run "reject_certificate_kms_alias" {
  command = plan

  variables {
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    # checkov:skip=CKV_SECRET_6: The AWS-managed key alias name, not a credential.
    operation_key_ring_certificate_secret_kms_key_arn = "alias/aws/secretsmanager"
  }

  expect_failures = [var.operation_key_ring_certificate_secret_kms_key_arn]
}

run "reject_plain_certificate_environment" {
  command = plan

  variables {
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    additional_env                            = { "operations:secretchannel:keyringcertificatepkcs12" = "private-material" }
  }

  expect_failures = [var.additional_env]
}

run "reject_certificate_path_override" {
  command = plan

  variables {
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    additional_env                            = { Operations__SecretChannel__KeyRingCertificatePath = "/tmp/unprotected.pfx" }
  }

  expect_failures = [var.additional_env]
}
