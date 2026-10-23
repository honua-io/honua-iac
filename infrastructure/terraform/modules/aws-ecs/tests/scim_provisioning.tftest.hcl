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

run "default_scim_disabled" {
  command = plan
  assert {
    condition     = length(local.scim_environment) == 0 && length(local.scim_secrets) == 0 && length(local.scim_secret_statements) == 0
    error_message = "Existing callers must receive no SCIM configuration or authority."
  }
}
run "immutable_scim_both_tasks" {
  command = apply
  variables {
    scim_provisioning = {
      oidc_issuer                     = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_fixture"
      bearer_token_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:private-scim-AbC123"
      bearer_token_secret_version_id  = "11111111-2222-3333-4444-555555555555"
      bearer_token_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    }
    canary_enabled                            = true
    deployment_mode                           = "MultiNode"
    redis_connection_string                   = "redis.example.internal:6379,password=test,ssl=true"
    redis_connection_cidrs                    = ["10.0.0.0/16"]
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-AbC123"
    file_storage_provider                     = "AwsS3"
    file_storage_aws_s3_bucket_name           = "honua-test-files"
  }
  assert {
    condition = alltrue([for definition in [aws_ecs_task_definition.this.container_definitions, aws_ecs_task_definition.canary[0].container_definitions] :
      length([for e in jsondecode(definition)[0].environment : e if e.name == "Scim__OidcIssuer" && e.value == var.scim_provisioning.oidc_issuer]) == 1 &&
      length([for e in jsondecode(definition)[0].environment : e if e.name == "Scim__BearerToken"]) == 0 &&
      length([for e in jsondecode(definition)[0].secrets : e if e.name == "Scim__BearerToken" && e.valueFrom == "${var.scim_provisioning.bearer_token_secret_arn}:::${var.scim_provisioning.bearer_token_secret_version_id}"]) == 1
    ])
    error_message = "Both real task definitions must inject the same immutable SCIM credential separately from public environment."
  }
  assert {
    condition = (length([for s in jsondecode(aws_iam_policy.secrets.policy).Statement : s if try(s.Sid == "ScimBearerRead" && s.Effect == "Allow" && s.Action == ["secretsmanager:GetSecretValue"] && s.Resource == [var.scim_provisioning.bearer_token_secret_arn] && s.Condition.StringEquals["secretsmanager:VersionId"] == var.scim_provisioning.bearer_token_secret_version_id, false)]) == 1 &&
    !contains(jsondecode(aws_iam_policy.secrets.policy).Statement[0].Resource, var.scim_provisioning.bearer_token_secret_arn))
    error_message = "SCIM read must be exact-ARN and version-constrained without an unconditional base-secret allow."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_policy.secrets.policy).Statement : s if try(s.Sid == "ScimBearerVersionCeiling" && s.Effect == "Deny" && s.Action == ["secretsmanager:GetSecretValue"] && s.Resource == [var.scim_provisioning.bearer_token_secret_arn] && s.Condition.StringNotEquals["secretsmanager:VersionId"] == var.scim_provisioning.bearer_token_secret_version_id, false)]) == 1
    error_message = "Missing or different versions must remain denied even with another overlapping allow."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_policy.secrets.policy).Statement : s if try(s.Sid == "ScimBearerDecrypt" && s.Effect == "Allow" && s.Action == ["kms:Decrypt"] && s.Resource == [var.scim_provisioning.bearer_token_secret_kms_key_arn] && s.Condition.StringEquals["kms:ViaService"] == "secretsmanager.us-east-1.amazonaws.com" && s.Condition.StringEquals["kms:EncryptionContext:SecretARN"] == var.scim_provisioning.bearer_token_secret_arn, false)]) == 1
    error_message = "CMK use must bind the exact SCIM secret and Secrets Manager region."
  }
  assert {
    condition     = output.ecs_task_definition_arn == aws_ecs_task_definition.this.arn && local.licensing_environment.Licensing__Mode == "Disabled"
    error_message = "Readback must expose the actual primary revision and retain the existing licensing contract."
  }
}
run "optional_unversioned_aws_key" {
  command = plan
  variables {
    scim_provisioning = {
      oidc_issuer             = "https://issuer.example.test"
      bearer_token_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:private-scim-AbC123"
    }
  }
  assert {
    condition     = local.scim_secrets[0].valueFrom == var.scim_provisioning.bearer_token_secret_arn && length(local.scim_secret_statements) == 1 && length(local.scim_secret_statements[0].Condition) == 0
    error_message = "Generic callers may omit a version and customer key; pilot callers must require their own immutable version."
  }
}
run "reject_http_issuer" {
  command = plan
  variables {
    scim_provisioning = { "oidc_issuer" = "http://issuer.example.test", "bearer_token_secret_arn" = "arn:aws:secretsmanager:us-east-1:123456789012:secret:private-scim-AbC123", "bearer_token_secret_version_id" = "11111111-2222-3333-4444-555555555555" }
  }
  expect_failures = [var.scim_provisioning]
}
run "reject_plaintext_bearer" {
  command = plan
  variables {
    scim_provisioning = { "oidc_issuer" = "https://issuer.example.test", "bearer_token_secret_arn" = "plaintext-secret", "bearer_token_secret_version_id" = "11111111-2222-3333-4444-555555555555" }
  }
  expect_failures = [var.scim_provisioning]
}
run "reject_version_in_base_arn" {
  command = plan
  variables {
    scim_provisioning = { "oidc_issuer" = "https://issuer.example.test", "bearer_token_secret_arn" = "arn:aws:secretsmanager:us-east-1:123456789012:secret:private-scim-AbC123:::version", "bearer_token_secret_version_id" = "11111111-2222-3333-4444-555555555555" }
  }
  expect_failures = [var.scim_provisioning]
}
run "reject_short_version" {
  command = plan
  variables {
    scim_provisioning = { "oidc_issuer" = "https://issuer.example.test", "bearer_token_secret_arn" = "arn:aws:secretsmanager:us-east-1:123456789012:secret:private-scim-AbC123", "bearer_token_secret_version_id" = "current" }
  }
  expect_failures = [var.scim_provisioning]
}
run "reject_blank_version" {
  command = plan
  variables {
    scim_provisioning = { "oidc_issuer" = "https://issuer.example.test", "bearer_token_secret_arn" = "arn:aws:secretsmanager:us-east-1:123456789012:secret:private-scim-AbC123", "bearer_token_secret_version_id" = "" }
  }
  expect_failures = [var.scim_provisioning]
}
run "reject_malformed_kms" {
  command = plan
  variables {
    scim_provisioning = { "oidc_issuer" = "https://issuer.example.test", "bearer_token_secret_arn" = "arn:aws:secretsmanager:us-east-1:123456789012:secret:private-scim-AbC123", "bearer_token_secret_version_id" = "11111111-2222-3333-4444-555555555555", "bearer_token_secret_kms_key_arn" = "alias/scim" }
  }
  expect_failures = [var.scim_provisioning]
}
run "reject_kms_region" {
  command = plan
  variables {
    scim_provisioning = { "oidc_issuer" = "https://issuer.example.test", "bearer_token_secret_arn" = "arn:aws:secretsmanager:us-east-1:123456789012:secret:private-scim-AbC123", "bearer_token_secret_version_id" = "11111111-2222-3333-4444-555555555555", "bearer_token_secret_kms_key_arn" = "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555" }
  }
  expect_failures = [terraform_data.scim_provisioning]
}
run "reject_kms_account" {
  command = plan
  variables {
    scim_provisioning = { "oidc_issuer" = "https://issuer.example.test", "bearer_token_secret_arn" = "arn:aws:secretsmanager:us-east-1:123456789012:secret:private-scim-AbC123", "bearer_token_secret_version_id" = "11111111-2222-3333-4444-555555555555", "bearer_token_secret_kms_key_arn" = "arn:aws:kms:us-east-1:999999999999:key/11111111-2222-3333-4444-555555555555" }
  }
  expect_failures = [terraform_data.scim_provisioning]
}
run "reject_kms_partition" {
  command = plan
  variables {
    scim_provisioning = { "oidc_issuer" = "https://issuer.example.test", "bearer_token_secret_arn" = "arn:aws:secretsmanager:us-east-1:123456789012:secret:private-scim-AbC123", "bearer_token_secret_version_id" = "11111111-2222-3333-4444-555555555555", "bearer_token_secret_kms_key_arn" = "arn:aws-cn:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555" }
  }
  expect_failures = [terraform_data.scim_provisioning]
}
run "reject_plaintext_primary" {
  command = plan
  variables {
    # checkov:skip=CKV_SECRET_6: Fixed rejected configuration key, not a credential; the value is test data.
    additional_env = { "Scim__BearerToken" = "must-not-reach-task" }
  }
  expect_failures = [terraform_data.scim_provisioning]
}
run "reject_colon_canary" {
  command = plan
  variables {
    canary_additional_env = { "sCim:BearerToken" = "must-not-reach-task" }
  }
  expect_failures = [terraform_data.scim_provisioning]
}
run "reject_prefixed_primary" {
  command = plan
  variables {
    additional_env = { "DOTNET_Scim__BearerToken" = "must-not-reach-task" }
  }
  expect_failures = [terraform_data.scim_provisioning]
}
run "reject_prefixed_canary" {
  command = plan
  variables {
    canary_additional_env = { "ASPNETCORE_Scim:OidcIssuer" = "must-not-reach-task" }
  }
  expect_failures = [terraform_data.scim_provisioning]
}
