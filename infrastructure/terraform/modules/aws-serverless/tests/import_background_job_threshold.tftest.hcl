# Import background-job threshold (import_background_job_threshold_bytes).
#
# honua-server hands an upload larger than Import:Limits:BackgroundJobThresholdBytes
# (default 100 MiB) to a background job instead of importing it inline. The
# release harness lowers it to 64 MiB on the Redis-on cells (honua-release#548,
# S10 large-import). The module renders it, like the database pool caps
# (local.db_pool_environment), on every server process: the API Lambda, the
# three control-plane event functions and the GP Batch job definitions. Null
# (default) renders nothing and keeps the server default.
#
# The release cell's inputs and mocks come from lambda_environment_budget.tftest.hcl
# (run 38046060497), which documents the Lambda 4 KB environment budget.

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
      account_id = "585192672263"
      arn        = "arn:aws:iam::585192672263:user/terraform-test"
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
      arn            = "arn:aws:ecr:us-east-1:585192672263:repository/honua-server"
      registry_id    = "585192672263"
      repository_url = "585192672263.dkr.ecr.us-east-1.amazonaws.com/honua-server"
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
      arn = "arn:aws:iam::585192672263:policy/honua-test"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::585192672263:role/honua-test"
    }
  }
  mock_resource "aws_batch_compute_environment" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:585192672263:compute-environment/honua-mock"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:585192672263:log-group:honua-mock:*"
    }
  }
  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      arn           = "arn:aws:apigateway:us-east-1::/apis/abcdefghij"
      execution_arn = "arn:aws:execute-api:us-east-1:585192672263:abcdefghij"
    }
  }
  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:585192672263:function:honua-mock"
    }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-1:585192672263:rule/honua-mock"
    }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:585192672263:secret:honua-mock-AbCdEf"
    }
  }
  # RDS Proxy (the release cell runs behind it); rds_proxy.tftest.hcl mocks.
  mock_resource "aws_db_proxy" {
    defaults = {
      arn      = "arn:aws:rds:us-east-1:585192672263:db-proxy:prx-0123456789abcdef0"
      endpoint = "honuarawsse380460-it-pg-proxy.proxy-abcdefghijkl.us-east-1.rds.amazonaws.com"
    }
  }
  mock_resource "aws_db_proxy_default_target_group" {
    defaults = {
      name = "default"
    }
  }
}

mock_provider "random" {}
mock_provider "null" {}

override_resource {
  target = aws_secretsmanager_secret.connection_string
  values = { arn = "arn:aws:secretsmanager:us-east-1:585192672263:secret:honuarawsse380460-it/connection-string-Ab12Cd" }
}
override_resource {
  target = aws_secretsmanager_secret.admin_password
  values = { arn = "arn:aws:secretsmanager:us-east-1:585192672263:secret:honuarawsse380460-it/admin-password-Ab12Cd" }
}
override_resource {
  target = aws_secretsmanager_secret.master_key
  values = { arn = "arn:aws:secretsmanager:us-east-1:585192672263:secret:honuarawsse380460-it/connection-encryption-master-key-Ab12Cd" }
}
override_resource {
  target = aws_secretsmanager_secret.redis_connection
  values = { arn = "arn:aws:secretsmanager:us-east-1:585192672263:secret:honuarawsse380460-it/redis-connection-Ab12Cd" }
}
override_resource {
  target = aws_batch_job_queue.gp
  values = { arn = "arn:aws:batch:us-east-1:585192672263:job-queue/honuarawsse380460-it-gp-queue" }
}
override_resource {
  target = aws_batch_job_definition.gp["s"]
  values = { arn = "arn:aws:batch:us-east-1:585192672263:job-definition/honuarawsse380460-it-gp-s:1", revision = 1 }
}
override_resource {
  target = aws_batch_job_definition.gp["m"]
  values = { arn = "arn:aws:batch:us-east-1:585192672263:job-definition/honuarawsse380460-it-gp-m:1", revision = 1 }
}
override_resource {
  target = aws_batch_job_definition.gp["l"]
  values = { arn = "arn:aws:batch:us-east-1:585192672263:job-definition/honuarawsse380460-it-gp-l:1", revision = 1 }
}
override_resource {
  target = aws_batch_job_definition.gp["xl"]
  values = { arn = "arn:aws:batch:us-east-1:585192672263:job-definition/honuarawsse380460-it-gp-xl:1", revision = 1 }
}

variables {
  # The release cell's base inputs (run 38046060497), with control-plane events
  # on so all three event functions exist.
  name_prefix      = "honuarawsse380460"
  environment      = "it"
  image            = "585192672263.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:acae8755a327933e11718de3b0317b6a420a2444ec21135debcb6087adf3f12b"
  gp_batch_image   = "ghcr.io/honua-io/honua-server@sha256:961b983de43ede21d315770dd2e4e1f3bf41dc358ce8ed156ddcb3101a3b6bcc"
  admin_password   = "Synthetic-Terraform-Test-Admin-4721!aA1"
  redis_auth_token = "aaaaAAAA1111&&&&aaaaAAAA1111&&&&"
  redis_enabled    = true
  enable_gp_batch  = true
  licensing_mode   = "Disabled"

  enable_control_plane_events = true

  operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:585192672263:secret:honua-release/cert/operation-key-ring-zDn618"
  audit_chain_key_secret_arn                = "arn:aws:secretsmanager:us-east-1:585192672263:secret:honua-release/cert/audit-chain-key-RLtpME"

  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI       = "true"
  }
}

run "null_by_default_renders_nothing" {
  command = apply

  assert {
    condition = alltrue([
      for env in [
        aws_lambda_function.this.environment[0].variables,
        aws_lambda_function.control_plane_reconcile[0].environment[0].variables,
        aws_lambda_function.control_plane_backstop[0].environment[0].variables,
        aws_lambda_function.control_plane_tick[0].environment[0].variables,
      ] : !contains(keys(env), "Import__Limits__BackgroundJobThresholdBytes")
    ])
    error_message = "With import_background_job_threshold_bytes null no Lambda may carry Import__Limits__BackgroundJobThresholdBytes."
  }

  assert {
    condition = alltrue([
      for tier, definition in aws_batch_job_definition.gp :
      length([for e in jsondecode(definition.container_properties).environment : e if e.name == "Import__Limits__BackgroundJobThresholdBytes"]) == 0
    ])
    error_message = "With import_background_job_threshold_bytes null no GP Batch job definition may carry Import__Limits__BackgroundJobThresholdBytes."
  }

  assert {
    condition     = output.import_background_job_threshold_bytes_rendered == { api = null, control_plane = null, gp_batch = null }
    error_message = "The rendered-threshold output must be null for every process when the input is null."
  }
}

run "set_renders_on_every_server_process" {
  command = apply

  variables {
    import_background_job_threshold_bytes = 67108864
  }

  assert {
    condition = alltrue([
      lookup(aws_lambda_function.this.environment[0].variables, "Import__Limits__BackgroundJobThresholdBytes", null) == "67108864",
      lookup(aws_lambda_function.control_plane_reconcile[0].environment[0].variables, "Import__Limits__BackgroundJobThresholdBytes", null) == null,
      lookup(aws_lambda_function.control_plane_backstop[0].environment[0].variables, "Import__Limits__BackgroundJobThresholdBytes", null) == null,
      lookup(aws_lambda_function.control_plane_tick[0].environment[0].variables, "Import__Limits__BackgroundJobThresholdBytes", null) == null,
    ])
    error_message = "The API Lambda must carry Import__Limits__BackgroundJobThresholdBytes=67108864; the three control-plane event functions serve no uploads and must not."
  }

  assert {
    condition = length(aws_batch_job_definition.gp) == 4 && alltrue([
      for tier, definition in aws_batch_job_definition.gp :
      one([for e in jsondecode(definition.container_properties).environment : e.value if e.name == "Import__Limits__BackgroundJobThresholdBytes"]) == "67108864"
    ])
    error_message = "Every GP Batch job definition tier must carry Import__Limits__BackgroundJobThresholdBytes=67108864."
  }

  assert {
    condition     = output.import_background_job_threshold_bytes_rendered == { api = "67108864", control_plane = null, gp_batch = "67108864" }
    error_message = "The rendered-threshold output must report the value for every process."
  }
}

run "typed_input_wins_over_additional_env" {
  command = plan

  variables {
    import_background_job_threshold_bytes = 67108864
    additional_env = {
      Import__Limits__BackgroundJobThresholdBytes = "1"
    }
  }

  assert {
    condition     = nonsensitive(sensitive(local.lambda_environment["Import__Limits__BackgroundJobThresholdBytes"])) == "67108864"
    error_message = "The typed input must win over the same key in additional_env."
  }
}

# The release aws-serverless/redis-on cell as honua-release
# e2e/targets/terraform_target.py (SERVERLESS_SPEC) builds it: GP Batch, RDS
# Proxy, control-plane events, the cell operations policy rules, Studio
# end-user authorization, the demo-site CORS origin, the per-run custom domain
# and the 64 MiB threshold (57 bytes per Lambda). Measured here: API 3855,
# reconcile 3942, scheduled-tick 3945 bytes (3798 / 3885 / 3888 without the
# threshold). That cell was already past the 256-byte margin the base release
# cell keeps (lambda_environment_budget.tftest.hcl) because of control-plane
# events, the proxy and the domain, so this run holds every Lambda to 128 bytes
# under Lambda's 4096-byte cap, which also absorbs a longer per-run hostname
# (ACM allows 64 octets, 3 more than this one, rendered twice).
run "release_redis_on_cell_with_threshold_fits_under_the_cap" {
  command = apply

  override_resource {
    target = aws_acm_certificate.api[0]
    values = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [{
        domain_name           = "honuarawsse380460-aws-serverless-redis-on.cert.demo.honua.io"
        resource_record_name  = "_abc.honuarawsse380460-aws-serverless-redis-on.cert.demo.honua.io."
        resource_record_type  = "CNAME"
        resource_record_value = "_def.acm-validations.aws."
      }]
    }
  }

  variables {
    import_background_job_threshold_bytes = 67108864
    enable_rds_proxy                      = true
    studio_end_user_authorization         = true
    cors_allowed_origins                  = ["http://127.0.0.1:18099"]
    operations_policy_rules = [
      { operation_id = "*", role = "scoped-admin-key", decision = "Allow", reason = "Release cell: scoped admin keys run typed operations" },
      { operation_id = "*", role = "admin", decision = "Allow", reason = "Release cell: bootstrap and full admins run typed operations" },
    ]
    domain_name     = "honuarawsse380460-aws-serverless-redis-on.cert.demo.honua.io"
    route53_zone_id = "Z089181827C9GKIKHXUTT"
  }

  assert {
    condition     = output.import_background_job_threshold_bytes_rendered == { api = "67108864", control_plane = null, gp_batch = "67108864" }
    error_message = "The release cell must carry the threshold on every server process."
  }

  assert {
    condition = alltrue([
      for env in [
        aws_lambda_function.this.environment[0].variables,
        aws_lambda_function.control_plane_reconcile[0].environment[0].variables,
        aws_lambda_function.control_plane_backstop[0].environment[0].variables,
        aws_lambda_function.control_plane_tick[0].environment[0].variables,
      ] : nonsensitive(sum([for k, v in env : length(k) + length(v) + 6]) + 1) <= 4096 - 128
    ])
    error_message = "The release aws-serverless/redis-on cell with the threshold must keep every Lambda environment at least 128 bytes under 4096 (API ${nonsensitive(sum([for k, v in aws_lambda_function.this.environment[0].variables : length(k) + length(v) + 6]) + 1)}, scheduled-tick ${nonsensitive(sum([for k, v in aws_lambda_function.control_plane_tick[0].environment[0].variables : length(k) + length(v) + 6]) + 1)} bytes)."
  }
}

run "reject_zero" {
  command = plan

  variables {
    import_background_job_threshold_bytes = 0
  }

  expect_failures = [var.import_background_job_threshold_bytes]
}

run "reject_negative" {
  command = plan

  variables {
    import_background_job_threshold_bytes = -1
  }

  expect_failures = [var.import_background_job_threshold_bytes]
}

run "reject_fraction" {
  command = plan

  variables {
    import_background_job_threshold_bytes = 1.5
  }

  expect_failures = [var.import_background_job_threshold_bytes]
}
