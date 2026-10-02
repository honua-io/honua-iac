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

run "bedrock_studio" {
  command = apply
  variables {
    enable_bedrock_ai = true
    bedrock_ai_region = "us-east-1"
    bedrock_ai_model  = "anthropic.claude-sonnet-4-5-20250929-v1:0"
    additional_env    = { StudioAiProxy__Providers__bedrock__Model = "unapproved-model" }
  }
  assert {
    condition     = one([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.value if e.name == "StudioAiProxy__Enabled"]) == "true" && one([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.value if e.name == "StudioAiProxy__DefaultProvider"]) == "bedrock" && one([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.value if e.name == "StudioAiProxy__Providers__bedrock__Kind"]) == "bedrock"
    error_message = "StudioAiProxy must select the IAM-authenticated Bedrock adapter."
  }
  assert {
    condition     = one([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.value if e.name == "StudioAiProxy__Providers__bedrock__Model"]) == "anthropic.claude-sonnet-4-5-20250929-v1:0" && one([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.value if e.name == "StudioAiProxy__Providers__bedrock__Region"]) == "us-east-1"
    error_message = "The running configuration must match the exact authorized model and region, despite additional_env."
  }
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.task_bedrock_invoke[0].policy).Statement[0].Resource) == toset(["arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0"])
    error_message = "A foundation model grant must contain exactly the pinned model ARN."
  }
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.task_bedrock_invoke[0].policy).Statement[0].Action) == toset(["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"])
    error_message = "Studio chat grants only inference, never model/agent administration."
  }
}
run "bedrock_disabled" {
  command = plan
  assert {
    condition     = length(aws_iam_role_policy.task_bedrock_invoke) == 0 && !contains(keys(local.bedrock_ai_environment), "StudioAiProxy__Enabled")
    error_message = "Disabled Bedrock must grant and configure nothing."
  }
}
run "reject_model_wildcard" {
  command = plan
  variables { bedrock_ai_model = "anthropic.*" }
  expect_failures = [var.bedrock_ai_model]
}

run "reject_unpinned_image_0" {
  command = plan
  variables { image = "ghcr.io/honua-io/honua-server:latest-lambda-aot-arm64" }
  expect_failures = [var.image]
}

run "reject_unpinned_image_1" {
  command = plan
  variables { image = "ghcr.io/honua-io/honua-server:v1.0.0" }
  expect_failures = [var.image]
}

run "reject_unpinned_image_2" {
  command = plan
  variables { image = "ghcr.io/honua-io/honua-server" }
  expect_failures = [var.image]
}

run "reject_unpinned_image_3" {
  command = plan
  variables { image = "ghcr.io/honua-io/honua-server@sha256:abc" }
  expect_failures = [var.image]
}

run "reject_mutable_canary_image" {
  command = plan
  variables { canary_image = "registry.example/honua:latest" }
  expect_failures = [var.canary_image]
}

run "bedrock_cross_region_profile" {
  command = apply
  variables {
    enable_bedrock_ai = true
    bedrock_ai_region = "us-east-1"
  }
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.task_bedrock_invoke[0].policy).Statement[0].Resource) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-4-5-20250929-v1:0",
      "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0",
      "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0",
      "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0"
    ])
    error_message = "The US profile grants exactly its three pinned model destinations and profile ARN."
  }
}

run "redis_on_requires_operation_certificate" {
  command = plan
  variables { redis_enabled = true }
  expect_failures = [aws_security_group.alb]
}

run "redis_off_has_no_certificate_dependency" {
  command = apply
  assert {
    condition     = !contains([for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets : s.name], "Operations__SecretChannel__KeyRingCertificatePkcs12")
    error_message = "Redis-off must not request operation certificate material."
  }
}

run "redis_on_injects_protected_certificate_for_both_slots" {
  command = apply
  variables {
    redis_enabled                             = true
    canary_enabled                            = true
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  }
  assert {
    condition = alltrue([
      for definition in [aws_ecs_task_definition.this.container_definitions, aws_ecs_task_definition.canary[0].container_definitions] :
      one([for s in jsondecode(definition)[0].secrets : s.valueFrom if s.name == "Operations__SecretChannel__KeyRingCertificatePkcs12"]) == "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123" &&
      !contains([for e in jsondecode(definition)[0].environment : e.name], "Operations__SecretChannel__KeyRingCertificatePkcs12")
    ])
    error_message = "Every Redis-backed task must resolve the operator-owned PKCS#12 secret through ECS, never a plaintext environment value."
  }
}

run "external_redis_also_requires_operation_certificate" {
  command = plan
  variables {
    redis_enabled           = false
    redis_connection_string = "redis.example.internal:6379,password=test,ssl=true"
    redis_connection_cidrs  = ["10.0.0.0/16"]
  }
  expect_failures = [aws_security_group.alb]
}

run "reject_plain_certificate_input" {
  command = plan
  variables { operation_key_ring_certificate_secret_arn = "base64-private-key-material" }
  expect_failures = [var.operation_key_ring_certificate_secret_arn]
}

run "reject_certificate_wildcard" {
  command = plan
  variables { operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-*" }
  expect_failures = [var.operation_key_ring_certificate_secret_arn]
}

run "reject_plain_certificate_environment" {
  command = plan
  variables { additional_env = { "operations:secretchannel:keyringcertificatepkcs12" = "private-material" } }
  expect_failures = [var.additional_env]
}

run "reject_canary_certificate_override" {
  command = plan
  variables { canary_additional_env = { Operations__SecretChannel__KeyRingCertificatePath = "/tmp/unprotected.pfx" } }
  expect_failures = [var.canary_additional_env]
}
