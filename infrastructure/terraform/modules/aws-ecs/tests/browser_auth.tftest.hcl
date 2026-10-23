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

run "default_browser_auth_disabled" {
  command = plan
  assert {
    condition     = length(local.browser_auth_environment) == 0 && length(local.browser_auth_secrets) == 0 && length(local.browser_auth_kms_arns) == 0
    error_message = "Existing customers must receive no browser auth settings or secret injection."
  }
}
run "typed_browser_auth_primary_and_canary" {
  command = apply
  variables {
    generic_oidc                              = { authority = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_fixture", client_id = "real-client-reference", admin_auth_callback_uri = "https://console.example.test/admin/auth/callback", client_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oidc-client-AbC123", client_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555" }
    operator_bearer                           = { signing_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-key-AbC123", signing_key_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-3333-4444-555555555555" }
    canary_enabled                            = true
    deployment_mode                           = "MultiNode"
    redis_connection_string                   = "redis.example.internal:6379,password=test,ssl=true"
    redis_connection_cidrs                    = ["10.0.0.0/16"]
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-AbC123"
    file_storage_provider                     = "AwsS3"
    file_storage_aws_s3_bucket_name           = "honua-test-files"
  }
  assert {
    condition = alltrue([for env in [local.primary_container_environment, local.canary_container_environment] : alltrue([
      contains([for e in env : "${e.name}=${e.value}"], "Oidc__Generic__Authority=${var.generic_oidc.authority}"),
      contains([for e in env : "${e.name}=${e.value}"], "Oidc__Generic__ClientId=${var.generic_oidc.client_id}"),
      contains([for e in env : "${e.name}=${e.value}"], "Oidc__Generic__Scopes__0=openid"),
      contains([for e in env : "${e.name}=${e.value}"], "Authentication__OperatorBearer__MaxLifetimeMinutes=30"),
      contains([for e in env : "${e.name}=${e.value}"], "Oidc__AdminAuthCallbackUri=https://console.example.test/admin/auth/callback"),
      !contains([for e in env : e.name], "Oidc__Generic__ClientSecret"),
      !contains([for e in env : e.name], "Authentication__OperatorBearer__SigningKey")
    ])])
    error_message = "Both tasks must have canonical nonsecret auth settings only."
  }
  assert {
    condition     = alltrue([for definition in [aws_ecs_task_definition.this.container_definitions, aws_ecs_task_definition.canary[0].container_definitions] : alltrue([for secret in local.browser_auth_secrets : contains([for e in jsondecode(definition)[0].secrets : "${e.name}=${e.valueFrom}"], "${secret.name}=${secret.valueFrom}")])])
    error_message = "Both task definitions must inject exact external secret ARNs."
  }
  assert {
    condition     = alltrue([for secret in local.browser_auth_secrets : contains(jsondecode(aws_iam_policy.secrets.policy).Statement[0].Resource, secret.valueFrom)])
    error_message = "Execution role must read only the selected auth secrets."
  }
  assert {
    condition     = length([for statement in jsondecode(aws_iam_policy.secrets.policy).Statement : statement if try(statement.Condition.StringEquals["kms:ViaService"] == "secretsmanager.us-east-1.amazonaws.com" && toset(statement.Resource) == toset(local.browser_auth_kms_arns) && statement.Action == ["kms:Decrypt"], false)]) == 1
    error_message = "Auth CMKs require an exact-key Secrets Manager ViaService decrypt grant."
  }
}
run "china_auth_key_uses_kms_service_name" {
  command = apply
  override_data {
    target = data.aws_region.current
    values = { id = "cn-north-1", name = "cn-north-1", region = "cn-north-1" }
  }
  override_data {
    target = data.aws_partition.current
    values = { id = "aws-cn", partition = "aws-cn", dns_suffix = "amazonaws.com.cn", reverse_dns_prefix = "cn.com.amazonaws" }
  }
  variables {
    operator_bearer = {
      signing_key_secret_arn  = "arn:aws-cn:secretsmanager:cn-north-1:123456789012:secret:operator-key-AbC123"
      signing_key_kms_key_arn = "arn:aws-cn:kms:cn-north-1:123456789012:key/22222222-2222-3333-4444-555555555555"
    }
  }
  assert {
    condition = length([for statement in jsondecode(aws_iam_policy.secrets.policy).Statement : statement if try(
      statement.Condition.StringEquals["kms:ViaService"] == "secretsmanager.cn-north-1.amazonaws.com" &&
      statement.Resource == [var.operator_bearer.signing_key_kms_key_arn] &&
    statement.Action == ["kms:Decrypt"], false)]) == 1
    error_message = "China auth keys must use the KMS ViaService name, not the regional endpoint DNS suffix."
  }
}

run "reject_http_authority" {
  command = plan
  variables {
    generic_oidc = { authority = "http://cognito-idp.us-east-1.amazonaws.com/us-east-1_fixture", client_id = "real-client-reference", admin_auth_callback_uri = "https://console.example.test/admin/auth/callback", client_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oidc-client-AbC123", client_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555" }
  }
  expect_failures = [var.generic_oidc]
}
run "reject_secret_selector" {
  command = plan
  variables {
    generic_oidc = { authority = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_fixture", client_id = "real-client-reference", admin_auth_callback_uri = "https://console.example.test/admin/auth/callback", client_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oidc-client-AbC123:password::", client_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555" }
  }
  expect_failures = [var.generic_oidc]
}
run "reject_operator_wildcard" {
  command = plan
  variables {
    operator_bearer = { signing_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:*", signing_key_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-3333-4444-555555555555" }
  }
  expect_failures = [var.operator_bearer]
}
run "reject_excess_lifetime" {
  command = plan
  variables {
    operator_bearer = { max_lifetime_minutes = 721, signing_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-key-AbC123", signing_key_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-3333-4444-555555555555" }
  }
  expect_failures = [var.operator_bearer]
}
run "reject_plaintext_primary" {
  command = plan
  variables {
    additional_env = { "oidc:generic:clientsecret" = "x" }
  }
  expect_failures = [var.additional_env]
}
run "reject_plaintext_canary" {
  command = plan
  variables {
    canary_additional_env = { Authentication__OperatorBearer__SigningKey = "x" }
  }
  expect_failures = [var.canary_additional_env]
}
run "reject_generic_override" {
  command = plan
  variables {
    generic_oidc   = { authority = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_fixture", client_id = "real-client-reference", admin_auth_callback_uri = "https://console.example.test/admin/auth/callback", client_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oidc-client-AbC123", client_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555" }
    additional_env = { "OIDC:GENERIC:Authority" = "https://other.test" }
  }
  expect_failures = [terraform_data.browser_auth]
}
run "reject_canary_operator_override" {
  command = plan
  variables {
    operator_bearer       = { signing_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-key-AbC123", signing_key_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-3333-4444-555555555555" }
    canary_additional_env = { "Authentication:OperatorBearer:Enabled" = "false" }
  }
  expect_failures = [terraform_data.browser_auth]
}
run "reject_static_and_generic" {
  command = plan
  variables {
    generic_oidc    = { authority = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_fixture", client_id = "real-client-reference", admin_auth_callback_uri = "https://console.example.test/admin/auth/callback", client_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oidc-client-AbC123", client_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555" }
    oidc_static_jwt = { issuer = "https://static.test", audience = "fixture", signing_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:static-AbC123" }
  }
  expect_failures = [terraform_data.browser_auth]
}

run "explicit_console_callback" {
  command = plan
  variables {
    generic_oidc = { authority = "https://issuer.example.test", client_id = "client", client_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:client-AbC123", admin_auth_callback_uri = "https://console.example.test/admin/auth/callback" }
  }
  assert {
    condition     = local.browser_auth_environment.Oidc__AdminAuthCallbackUri == "https://console.example.test/admin/auth/callback"
    error_message = "Explicit broker callback must be rendered without changing Server PublicBaseUrl."
  }
}

run "reject_callback_0" {
  command = plan
  variables {
    generic_oidc = { authority = "https://issuer.example.test", client_id = "client", client_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:client-AbC123", admin_auth_callback_uri = "http://console.test/admin/auth/callback" }
  }
  expect_failures = [var.generic_oidc]
}

run "reject_callback_1" {
  command = plan
  variables {
    generic_oidc = { authority = "https://issuer.example.test", client_id = "client", client_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:client-AbC123", admin_auth_callback_uri = "https://user@console.test/admin/auth/callback" }
  }
  expect_failures = [var.generic_oidc]
}

run "reject_callback_2" {
  command = plan
  variables {
    generic_oidc = { authority = "https://issuer.example.test", client_id = "client", client_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:client-AbC123", admin_auth_callback_uri = "https://console.test/admin/auth/callback?x=1" }
  }
  expect_failures = [var.generic_oidc]
}

run "reject_callback_3" {
  command = plan
  variables {
    generic_oidc = { authority = "https://issuer.example.test", client_id = "client", client_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:client-AbC123", admin_auth_callback_uri = "https://console.test/admin/auth/callback#x" }
  }
  expect_failures = [var.generic_oidc]
}

run "reject_callback_4" {
  command = plan
  variables {
    generic_oidc = { authority = "https://issuer.example.test", client_id = "client", client_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:client-AbC123", admin_auth_callback_uri = "https://console.test/signin-oidc" }
  }
  expect_failures = [var.generic_oidc]
}

run "reject_callback_override" {
  command = plan
  variables {
    generic_oidc          = { authority = "https://issuer.example.test", client_id = "client", client_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:client-AbC123" }
    canary_additional_env = { "Oidc:AdminAuthCallbackUri" = "https://other.test/admin/auth/callback" }
  }
  expect_failures = [terraform_data.browser_auth]
}

run "reject_reused_client_and_signing_secret" {
  command = plan
  variables {
    generic_oidc    = { authority = "https://issuer.example.test", client_id = "client", client_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:client-AbC123" }
    operator_bearer = { signing_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:client-AbC123" }
  }
  expect_failures = [terraform_data.browser_auth]
}
