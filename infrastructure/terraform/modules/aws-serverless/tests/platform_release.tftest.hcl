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

run "default_declares_no_release" {
  command = plan
  assert {
    condition     = alltrue([for environment in values(local.platform_release_environment) : length(environment) == 0])
    error_message = "A null typed release must render no release keys."
  }
}

run "digest_pinned_identity_reaches_serving_slots" {
  command = apply
  variables {
    platform_release = {
      version                    = "2026.1.1-rc.3"
      serving_artifact_reference = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      workers                    = [{ runtime_profile = "cpu", artifact_reference = "ghcr.io/honua-io/honua-worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }]
    }
  }
  assert {
    condition     = alltrue([for environment in values(local.platform_release_environment) : environment.ControlPlane__PlatformRelease__Version == "2026.1.1-rc.3" && environment.ControlPlane__PlatformRelease__ServingArtifactReference == "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" && environment.ControlPlane__PlatformRelease__Workers__0__RuntimeProfile == "cpu" && environment.ControlPlane__PlatformRelease__Workers__0__ArtifactReference == "ghcr.io/honua-io/honua-worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"])
    error_message = "Every serving slot must carry the exact version and serving/worker digest identities."
  }
  assert {
    condition     = local.lambda_environment.ControlPlane__PlatformRelease__Version == "2026.1.1-rc.3" && local.lambda_environment.ControlPlane__PlatformRelease__Workers__0__RuntimeProfile == "cpu"
    error_message = "The release identity must reach the actual serving environment."
  }
}

run "mutable_serving_tag_is_rejected" {
  command = plan
  variables {
    platform_release = { version = "2026.1.1-rc.3", serving_artifact_reference = "ghcr.io/honua-io/honua-server:latest" }
  }
  expect_failures = [var.platform_release]
}

run "empty_version_is_rejected" {
  command = plan
  variables {
    platform_release = { version = " ", serving_artifact_reference = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  }
  expect_failures = [var.platform_release]
}

run "typed_identity_replaces_stale_raw_subtree" {
  command = apply
  variables {
    platform_release = { version = "2026.1.1-rc.4", serving_artifact_reference = "ghcr.io/honua-io/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
    additional_env = {
      ControlPlane__PlatformRelease__Version                         = "stale"
      ControlPlane__PlatformRelease__Workers__9__ArtifactReference   = "stale-worker"
      "controlplane__platformrelease__Workers__0__ArtifactReference" = "alternate-delimiter-stale-worker"
      Existing_Operator_Option                                       = "preserved"
    }
  }
  assert {
    condition     = local.lambda_environment.ControlPlane__PlatformRelease__Version == "2026.1.1-rc.4" && local.lambda_environment.Existing_Operator_Option == "preserved" && !contains(keys(local.lambda_environment), "ControlPlane__PlatformRelease__Workers__9__ArtifactReference") && !contains(keys(local.lambda_environment), "controlplane__platformrelease__Workers__0__ArtifactReference")
    error_message = "Typed release configuration must override stale raw release keys without changing unrelated operator settings."
  }
}

run "default_preserves_existing_raw_configuration" {
  command = apply
  variables {
    additional_env = { ControlPlane__PlatformRelease__Version = "existing-operator-version" }
  }
  assert {
    condition     = local.lambda_environment.ControlPlane__PlatformRelease__Version == "existing-operator-version"
    error_message = "Omitting the new input must preserve existing callers."
  }
}

run "release_identity_fits_real_lambda_environment_budget" {
  command = apply
  variables {
    platform_release = { version = "2026.1.1-rc.4", serving_artifact_reference = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
  }
  assert {
    condition     = local.lambda_environment_bytes.api <= 4096 && local.lambda_environment.ControlPlane__PlatformRelease__ServingArtifactReference == var.platform_release.serving_artifact_reference
    error_message = "The actual API Lambda environment must contain the release identity and fit AWS's 4 KB ceiling."
  }
}

run "mutable_worker_tag_is_rejected" {
  command = plan
  variables {
    platform_release = {
      version                    = "2026.1.1-rc.3"
      serving_artifact_reference = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      workers                    = [{ artifact_reference = "ghcr.io/honua-io/honua-worker:latest" }]
    }
  }
  expect_failures = [var.platform_release]
}
