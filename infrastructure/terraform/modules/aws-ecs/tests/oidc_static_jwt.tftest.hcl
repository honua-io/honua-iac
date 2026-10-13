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
    condition     = length([for entry in local.container_secrets : entry if entry.name == "Oidc__TokenValidation__SymmetricSigningKey" && entry.valueFrom == var.oidc_static_jwt.signing_key_secret_arn]) == 1 && !contains([for entry in local.primary_container_environment : entry.name], "Oidc__TokenValidation__SymmetricSigningKey")
    error_message = "The signing key must be an ECS secret reference, never a plaintext environment entry."
  }
  assert {
    condition     = contains(jsondecode(aws_iam_policy.secrets.policy).Statement[0].Resource, var.oidc_static_jwt.signing_key_secret_arn) && length([for entry in jsondecode(aws_iam_policy.secrets.policy).Statement : entry if contains(entry.Resource, var.oidc_static_jwt.signing_key_kms_key_arn)]) == 1
    error_message = "The execution role must receive only the exact signing secret and KMS key."
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
    condition     = length([for entry in local.container_secrets : entry if entry.name == "Oidc__TokenValidation__SymmetricSigningKey" && entry.valueFrom == "${var.oidc_static_jwt.signing_key_secret_arn}:::${var.oidc_static_jwt.signing_key_secret_version_id}"]) == 1
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
