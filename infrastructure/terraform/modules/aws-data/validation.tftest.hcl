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
