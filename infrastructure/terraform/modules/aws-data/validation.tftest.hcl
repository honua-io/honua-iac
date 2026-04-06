mock_provider "aws" {}
mock_provider "random" {}
mock_provider "null" {}

override_data {
  target = data.aws_availability_zones.available

  values = {
    names = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
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

run "db_maintenance_window_format" {
  command = plan

  variables {
    db_maintenance_window = "Sunday-04:00"
  }

  expect_failures = [
    var.db_maintenance_window,
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

run "operations_metadata_shape" {
  command = plan

  assert {
    condition     = output.operations_metadata.database.port == 5432
    error_message = "Expected operations metadata to expose PostgreSQL port 5432."
  }

  assert {
    condition     = output.operations_metadata.database.backup_retention_days == 3
    error_message = "Expected the default dev backup retention to be 3 days."
  }

  assert {
    condition     = output.operations_metadata.cache.enabled == true
    error_message = "Expected Redis metadata to be enabled by default."
  }
}
