# The rc.2 overlay itself, planned with mocked providers. Run with the preset:
#   terraform test -test-directory=preset-tests -var-file=presets/rc2.tfvars.example
# Only customer inputs are set here, so every asserted value comes from the preset.

mock_provider "aws" {
  source = "./tests/mocks/aws"
}

mock_provider "random" {
  mock_resource "random_password" {
    defaults = { result = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  }
}
mock_provider "null" {}

variables {
  audit_chain_key_secret_arn             = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
  honua_image                            = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  postgis_bootstrap_image                = "docker.io/library/postgres@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  honua_admin_password                   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  honua_connection_encryption_master_key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  db_password                            = "cccccccccccccccccccccccccccccccc"

  existing_vpc_id             = "vpc-0123456789abcdef0"
  existing_vpc_cidr           = "10.0.0.0/16"
  existing_public_subnet_ids  = ["subnet-00000000000000001", "subnet-00000000000000002"]
  existing_private_subnet_ids = ["subnet-00000000000000003", "subnet-00000000000000004"]

  domain_name         = "maps.example.com"
  alb_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  cdn = {
    viewer_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  }
  static_console = {
    viewer_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    bundle_version         = "rc.2"
  }
}

run "rc2_preset_surge_capacity_fits_the_database" {
  command = plan

  assert {
    condition     = var.desired_count >= 2 && var.max_capacity > var.desired_count && var.deployment_mode == "MultiNode"
    error_message = "The rc.2 preset keeps at least two tasks and leaves room to scale out."
  }
  assert {
    condition     = var.shared_state_backend == "postgres" && !var.redis_enabled && output.redis_primary_endpoint == null
    error_message = "The rc.2 preset runs without Redis."
  }
  assert {
    condition     = var.autoscaling_requests_per_target != null
    error_message = "The rc.2 preset scales on request count as well as CPU."
  }
  assert {
    condition     = output.db_connection_budget.source == "derived" && output.db_connection_budget.max_processes == var.max_capacity * 2
    error_message = "The pool must be derived for the maximum task count, doubled for a rolling deployment."
  }
  assert {
    condition     = output.db_connection_budget.pool_size >= 10 && output.db_connection_budget.worst_case_connections <= output.db_connection_budget.usable_connections
    error_message = "At the preset's maximum task count each pool needs at least ten connections within the database's usable connections; raise db_instance_class or lower max_capacity."
  }
}
