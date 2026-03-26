mock_provider "aws" {}
mock_provider "random" {}
mock_provider "null" {}

override_data {
  target = data.aws_availability_zones.available

  values = {
    names = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}

override_data {
  target = data.aws_iam_policy_document.lambda_assume

  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

variables {
  image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua:test-lambda"
  admin_password = "test-password-that-is-at-least-32-chars!"
}

# --- Variable validation tests ---

run "admin_password_minimum_length" {
  command = plan

  variables {
    admin_password = "short"
  }

  expect_failures = [
    var.admin_password,
  ]
}

run "image_reference_requires_tag_or_digest" {
  command = plan

  variables {
    image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua"
  }

  expect_failures = [
    var.image,
  ]
}

run "lambda_timeout_too_low" {
  command = plan

  variables {
    lambda_timeout_seconds = 5
  }

  expect_failures = [
    var.lambda_timeout_seconds,
  ]
}

run "lambda_timeout_too_high" {
  command = plan

  variables {
    lambda_timeout_seconds = 901
  }

  expect_failures = [
    var.lambda_timeout_seconds,
  ]
}

run "lambda_alias_version_rejects_latest" {
  command = plan

  variables {
    lambda_alias_version = "$LATEST"
  }

  expect_failures = [
    var.lambda_alias_version,
  ]
}

run "app_storage_prefix_must_not_start_with_slash" {
  command = plan

  variables {
    app_storage_prefix = "/validation"
  }

  expect_failures = [
    var.app_storage_prefix,
  ]
}

run "db_allocated_storage_minimum" {
  command = plan

  variables {
    db_allocated_storage = 19
  }

  expect_failures = [
    var.db_allocated_storage,
  ]
}

run "db_max_allocated_storage_must_cover_allocated_storage" {
  command = plan

  variables {
    db_allocated_storage     = 50
    db_max_allocated_storage = 40
  }

  expect_failures = [
    check.db_storage_autoscaling_bounds,
  ]
}

run "existing_db_reuse_requires_cidrs" {
  command = plan

  variables {
    existing_db_endpoint          = "db.example.internal"
    existing_db_connection_string = "Host=db.example.internal;Port=5432;Database=honua;Username=honua;Password=test-password-that-is-at-least-32-chars!;SSL Mode=Require"
    existing_db_cidrs             = []
    enable_postgis                = false
  }

  expect_failures = [
    check.existing_db_reuse_requires_cidrs,
  ]
}

run "existing_db_reuse_deduplicates_postgresql_egress" {
  command = plan

  variables {
    existing_db_endpoint          = "db.example.internal"
    existing_db_connection_string = "Host=db.example.internal;Port=5432;Database=honua;Username=honua;Password=test-password-that-is-at-least-32-chars!;SSL Mode=Require"
    existing_db_cidrs             = ["10.0.0.0/16", "10.0.0.0/16"]
    enable_postgis                = false
  }

  assert {
    condition     = length([for rule in aws_security_group.lambda.egress : rule if rule.from_port == 5432 && rule.to_port == 5432]) == 1
    error_message = "Expected a single PostgreSQL egress rule when reusing an existing database."
  }

  assert {
    condition     = flatten([for rule in aws_security_group.lambda.egress : rule.cidr_blocks if rule.from_port == 5432 && rule.to_port == 5432]) == ["10.0.0.0/16"]
    error_message = "Expected PostgreSQL egress CIDRs to be deduplicated for existing database reuse."
  }
}

run "redis_reuse_is_exclusive" {
  command = plan

  variables {
    redis_enabled           = true
    redis_connection_string = "redis.example.internal:6379,password=test,ssl=true"
    redis_connection_cidrs  = ["10.0.0.0/16"]
  }

  expect_failures = [
    check.redis_reuse_is_exclusive,
  ]
}

run "redis_auth_token_rejects_unsupported_special_characters" {
  command = plan

  variables {
    redis_auth_token = "invalid-redis-token.with-dot"
  }

  expect_failures = [
    var.redis_auth_token,
  ]
}

run "postgis_readiness_max_attempts_minimum" {
  command = plan

  variables {
    postgis_readiness_max_attempts = 0
  }

  expect_failures = [
    var.postgis_readiness_max_attempts,
  ]
}

run "postgis_readiness_sleep_seconds_minimum" {
  command = plan

  variables {
    postgis_readiness_sleep_seconds = 0
  }

  expect_failures = [
    var.postgis_readiness_sleep_seconds,
  ]
}

# --- Control-plane output shape tests ---

run "control_plane_outputs_shape" {
  command = plan

  assert {
    condition     = output.control_plane_target_kind == "AwsLambda"
    error_message = "Expected target kind AwsLambda."
  }

  assert {
    condition     = output.control_plane_backend_name == "honua-gitops-aws-lambda"
    error_message = "Expected backend name honua-gitops-aws-lambda."
  }

  assert {
    condition     = output.control_plane_telemetry_policy == "honua-http"
    error_message = "Expected telemetry policy honua-http."
  }

  assert {
    condition     = output.control_plane_current_image == "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua:test-lambda"
    error_message = "Expected the Lambda image to surface through the unified control-plane outputs."
  }

  assert {
    condition     = !output.marketplace_profile.eligible
    error_message = "Expected Lambda to be excluded from marketplace-targeted bundles."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).target.kind == "AwsLambda"
    error_message = "Expected the unified control-plane contract to expose the Lambda target kind."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).target_kind == "AwsLambda"
    error_message = "Expected the top-level deploy contract target_kind to match AwsLambda."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).artifact_reference.desired == "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua:test-lambda"
    error_message = "Expected the top-level desired artifact reference to match the Lambda image."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).secret_refs.database_connection.kind == "aws-secrets-manager"
    error_message = "Expected the top-level deploy contract to expose the DB secret reference kind."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).secret_refs.connection_encryption_master_key.kind == "aws-secrets-manager"
    error_message = "Expected the top-level deploy contract to expose the connection encryption secret reference kind."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).health_policy.telemetry_policy == "honua-http"
    error_message = "Expected the top-level deploy contract to expose the honua-http telemetry policy."
  }

  assert {
    condition     = output.operations_metadata.database.port == 5432
    error_message = "Expected operations metadata to expose PostgreSQL port 5432."
  }

  assert {
    condition     = output.operations_metadata.workload.alias_name == "live"
    error_message = "Expected operations metadata to expose the default live alias."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).marketplace.blocker_reason != null
    error_message = "Expected the marketplace profile to record why Lambda is excluded."
  }
}

run "app_storage_outputs_shape" {
  command = plan

  variables {
    app_storage_enabled = true
  }

  assert {
    condition     = output.app_storage_enabled
    error_message = "Expected application storage to be enabled."
  }

  assert {
    condition     = output.operations_metadata.object_storage.kind == "s3"
    error_message = "Expected operations metadata to expose S3 object storage."
  }
}
