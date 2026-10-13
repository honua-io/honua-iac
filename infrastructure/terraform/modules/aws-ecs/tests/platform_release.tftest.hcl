# Import background-job threshold (import_background_job_threshold_bytes).
#
# honua-server hands an upload larger than Import:Limits:BackgroundJobThresholdBytes
# (default 100 MiB) to a background job instead of importing it inline. The
# release harness lowers it on Redis-on cells (honua-release#548, S10
# large-import). The module renders the key only when the input is set, on
# the primary and canary containers; null keeps the server default.

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

run "default_declares_no_release" {
  command = plan
  assert {
    condition     = alltrue([for environment in values(local.platform_release_environment) : length(environment) == 0])
    error_message = "A null typed release must render no release keys."
  }
}

run "digest_pinned_identity_reaches_serving_slots" {
  command = plan
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
    condition     = alltrue([for environment in [tomap({ for entry in local.primary_container_environment : entry.name => entry.value }), tomap({ for entry in local.canary_container_environment : entry.name => entry.value })] : environment.ControlPlane__PlatformRelease__Version == "2026.1.1-rc.3" && environment.ControlPlane__PlatformRelease__Workers__0__RuntimeProfile == "cpu"])
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

run "canary_keeps_distinct_candidate_identity" {
  command = plan
  variables {
    platform_release        = { version = "2026.1.1-rc.3", serving_artifact_reference = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
    canary_platform_release = { version = "2026.1.1-rc.4", serving_artifact_reference = "ghcr.io/honua-io/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
  }
  assert {
    condition     = local.platform_release_environment.primary.ControlPlane__PlatformRelease__Version == "2026.1.1-rc.3" && local.platform_release_environment.canary.ControlPlane__PlatformRelease__Version == "2026.1.1-rc.4" && local.platform_release_environment.canary.ControlPlane__PlatformRelease__ServingArtifactReference == "ghcr.io/honua-io/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    error_message = "Staging a candidate must not relabel the still-serving prior release."
  }
}

run "typed_identity_replaces_stale_raw_subtree" {
  command = plan
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
    condition     = tomap({ for entry in local.primary_container_environment : entry.name => entry.value }).ControlPlane__PlatformRelease__Version == "2026.1.1-rc.4" && tomap({ for entry in local.primary_container_environment : entry.name => entry.value }).Existing_Operator_Option == "preserved" && !contains(keys(tomap({ for entry in local.primary_container_environment : entry.name => entry.value })), "ControlPlane__PlatformRelease__Workers__9__ArtifactReference") && !contains(keys(tomap({ for entry in local.primary_container_environment : entry.name => entry.value })), "controlplane__platformrelease__Workers__0__ArtifactReference")
    error_message = "Typed release configuration must override stale raw release keys without changing unrelated operator settings."
  }
}

run "default_preserves_existing_raw_configuration" {
  command = plan
  variables {
    additional_env = { ControlPlane__PlatformRelease__Version = "existing-operator-version" }
  }
  assert {
    condition     = tomap({ for entry in local.primary_container_environment : entry.name => entry.value }).ControlPlane__PlatformRelease__Version == "existing-operator-version"
    error_message = "Omitting the new input must preserve existing callers."
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
