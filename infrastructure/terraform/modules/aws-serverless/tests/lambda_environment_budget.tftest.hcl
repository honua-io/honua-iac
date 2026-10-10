# Lambda environment budget (honua-release e2e-cloud-aws run 38046060497,
# aws-serverless/redis-on, iac 57b9417): CreateFunction failed with
# "environment variables ... exceeded the 4KB limit. Measured size: 4118 bytes"
# once the audit-chain key reference joined Redis, the key-ring certificate and
# GP Batch. Lambda's 4 KB cap covers every key and value and is hard.
#
# Lambda measures the variables as a JSON object: sum(len(key) + len(value) + 6)
# + 1 (quotes, colon and comma per entry, plus the braces). For that run's
# inputs, reproduced below, it gives exactly the 4118 bytes Lambda reported
# against the module at 57b9417. The budget asserted is 4096
# minus a 256-byte margin, for every Lambda that carries the environment (the
# API function and the three control-plane event functions, which add the
# event-handler selectors).
#
# Realistic shapes matter: a 12-digit account, the harness cell name
# honuarawsse380460-it, the release secrets' real names and the run's images.

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
  # The failing cell's inputs (run 38046060497).
  name_prefix      = "honuarawsse380460"
  environment      = "it"
  image            = "585192672263.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:acae8755a327933e11718de3b0317b6a420a2444ec21135debcb6087adf3f12b"
  gp_batch_image   = "ghcr.io/honua-io/honua-server@sha256:961b983de43ede21d315770dd2e4e1f3bf41dc358ce8ed156ddcb3101a3b6bcc"
  admin_password   = "Synthetic-Terraform-Test-Admin-4721!aA1"
  redis_auth_token = "aaaaAAAA1111&&&&aaaaAAAA1111&&&&"
  redis_enabled    = true
  enable_gp_batch  = true
  licensing_mode   = "Disabled"

  operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:585192672263:secret:honua-release/cert/operation-key-ring-zDn618"
  audit_chain_key_secret_arn                = "arn:aws:secretsmanager:us-east-1:585192672263:secret:honua-release/cert/audit-chain-key-RLtpME"

  # examples/aws-serverless passes these through additional_env.
  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI       = "true"
  }
}

run "release_redis_on_cell_fits_with_margin" {
  command = apply

  assert {
    condition     = nonsensitive(sum([for k, v in aws_lambda_function.this.environment[0].variables : length(k) + length(v) + 6]) + 1) <= 4096 - 256
    error_message = "The release aws-serverless/redis-on cell's Lambda environment is ${nonsensitive(sum([for k, v in aws_lambda_function.this.environment[0].variables : length(k) + length(v) + 6]) + 1)} bytes; it must stay at least 256 bytes under Lambda's 4096-byte cap."
  }

  assert {
    condition     = local.lambda_environment_bytes.api >= nonsensitive(sum([for k, v in aws_lambda_function.this.environment[0].variables : length(k) + length(v) + 6]) + 1)
    error_message = "The module's plan-time estimate must never be smaller than the environment it guards."
  }

  # Same-account, same-region operator secrets travel by name.
  assert {
    condition = alltrue([
      aws_lambda_function.this.environment[0].variables["AuditLog__ChainVerification__Key"] == "aws:secretsmanager:honua-release/cert/audit-chain-key",
      aws_lambda_function.this.environment[0].variables["Operations__SecretChannel__KeyRingCertificatePkcs12"] == "aws:secretsmanager:honua-release/cert/operation-key-ring",
    ])
    error_message = "Operator secrets in the function's account and region must be referenced by name."
  }

  # Module secrets travel by name, except one whose name ends like an ARN suffix.
  assert {
    condition = alltrue([
      aws_lambda_function.this.environment[0].variables["HONUA_ADMIN_PASSWORD"] == "aws:secretsmanager:honuarawsse380460-it/admin-password",
      aws_lambda_function.this.environment[0].variables["Security__ConnectionEncryption__MasterKey"] == "aws:secretsmanager:honuarawsse380460-it/connection-encryption-master-key",
      aws_lambda_function.this.environment[0].variables["ConnectionStrings__redis"] == "aws:secretsmanager:honuarawsse380460-it/redis-connection",
      aws_lambda_function.this.environment[0].variables["ConnectionStrings__DefaultConnection"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:585192672263:secret:honuarawsse380460-it/connection-string-Ab12Cd",
    ])
    error_message = "Module secrets must be referenced by name unless the name ends in '-' plus six characters (ambiguous with an ARN suffix)."
  }

  # GP Batch substrate by name and pinned revision; no redundant region.
  assert {
    condition = alltrue([
      aws_lambda_function.this.environment[0].variables["ControlPlane__ExecutionWorkloads__0__ParameterEntries__0__Key"] == "batch.job_queue_arn",
      aws_lambda_function.this.environment[0].variables["ControlPlane__ExecutionWorkloads__0__ParameterEntries__0__Value"] == "honuarawsse380460-it-gp-queue",
      aws_lambda_function.this.environment[0].variables["ControlPlane__ExecutionWorkloads__0__ParameterEntries__1__Key"] == "batch.job_definition_arn.s",
      aws_lambda_function.this.environment[0].variables["ControlPlane__ExecutionWorkloads__0__ParameterEntries__1__Value"] == "honuarawsse380460-it-gp-s:1",
      aws_lambda_function.this.environment[0].variables["ControlPlane__ExecutionWorkloads__0__ParameterEntries__4__Key"] == "batch.job_definition_arn.xl",
      aws_lambda_function.this.environment[0].variables["ControlPlane__ExecutionWorkloads__0__ParameterEntries__4__Value"] == "honuarawsse380460-it-gp-xl:1",
      !contains(values(aws_lambda_function.this.environment[0].variables), "batch.region"),
    ])
    error_message = "The GP workload must carry the queue name and name:revision job definitions, without batch.region."
  }

  # The GP job keeps full ARNs: it has no 4 KB cap.
  assert {
    condition     = one([for e in jsondecode(aws_batch_job_definition.gp["s"].container_properties).environment : e.value if e.name == "AuditLog__ChainVerification__Key"]) == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:585192672263:secret:honua-release/cert/audit-chain-key-RLtpME"
    error_message = "The GP job definition must keep the full audit-chain key ARN."
  }
}

run "release_cell_budget_is_known_at_plan" {
  command = plan

  assert {
    condition     = local.lambda_environment_bytes.api <= 4096 - 256
    error_message = "The environment estimate must be computable, and within budget, at plan time."
  }
}

# Every optional 2026.1 feature at once (the Pro license is 2026.2, below). The
# iac-only reductions bring this under the cap but NOT under the 256-byte margin
# the release cell keeps: the scheduled-tick function measures 3981 bytes.
# A wider margin needs a server change (see the module README, "Lambda
# environment budget"), so this run asserts the margin actually achieved.
run "every_optional_feature_fits" {
  command = apply

  variables {
    operation_key_ring_certificate_secret_kms_key_arn              = "arn:aws:kms:us-east-1:585192672263:key/00000000-0000-0000-0000-000000000002"
    audit_chain_key_secret_kms_key_arn                             = "arn:aws:kms:us-east-1:585192672263:key/00000000-0000-0000-0000-000000000003"
    enable_bedrock_ai                                              = true
    enable_xray_tracing                                            = true
    enable_amazon_location_geocoding                               = true
    enable_control_plane_events                                    = true
    cors_allowed_origins                                           = ["https://console.honua.example.com", "https://studio.honua.example.com"]
    request_secret_reference_allowed_environment_variables         = ["HONUA_IMPORT_TOKEN"]
    request_secret_reference_allowed_environment_variable_prefixes = ["HONUA_IMPORT_"]
    request_secret_reference_allowed_secret_reference_prefixes     = ["aws:secretsmanager:honua/imports/"]
  }

  assert {
    condition = alltrue([
      for env in [
        aws_lambda_function.this.environment[0].variables,
        aws_lambda_function.control_plane_reconcile[0].environment[0].variables,
        aws_lambda_function.control_plane_backstop[0].environment[0].variables,
        aws_lambda_function.control_plane_tick[0].environment[0].variables,
      ] : nonsensitive(sum([for k, v in env : length(k) + length(v) + 6]) + 1) <= 4096 - 64
    ])
    error_message = "With every optional feature on, each Lambda environment must stay at least 64 bytes under 4096 (API ${nonsensitive(sum([for k, v in aws_lambda_function.this.environment[0].variables : length(k) + length(v) + 6]) + 1)}, scheduled-tick ${nonsensitive(sum([for k, v in aws_lambda_function.control_plane_tick[0].environment[0].variables : length(k) + length(v) + 6]) + 1)} bytes)."
  }
}

# The 2026.2 Pro license adds its secret reference and an inline trusted public
# key. On top of every other feature the API function still fits, but the
# control-plane event functions (API environment plus their selectors) no
# longer fit Lambda's 4 KB, and the module must say so at PLAN time instead of
# letting CreateFunction fail.
run "pro_license_on_top_of_every_feature_fails_at_plan" {
  command = plan

  variables {
    enable_bedrock_ai                                              = true
    enable_xray_tracing                                            = true
    enable_amazon_location_geocoding                               = true
    enable_control_plane_events                                    = true
    cors_allowed_origins                                           = ["https://console.honua.example.com", "https://studio.honua.example.com"]
    request_secret_reference_allowed_environment_variables         = ["HONUA_IMPORT_TOKEN"]
    request_secret_reference_allowed_environment_variable_prefixes = ["HONUA_IMPORT_"]
    request_secret_reference_allowed_secret_reference_prefixes     = ["aws:secretsmanager:honua/imports/"]
    enable_pro_license                                             = true
    pro_license_secret_arn                                         = "arn:aws:secretsmanager:us-east-1:585192672263:secret:honua-release/cert/license-pro-Q1w2E3"
    pro_license_trusted_public_key                                 = "base64url:Y2XgDBncW5w6n7L3YG-T6HxX51DGybWazt0_gubk30k"
  }

  expect_failures = [
    aws_lambda_function.control_plane_reconcile,
    aws_lambda_function.control_plane_backstop,
    aws_lambda_function.control_plane_tick,
  ]
}

# Operator secrets keep their full ARN when a name would be wrong or ambiguous.
run "foreign_or_ambiguous_operator_secrets_keep_their_arn" {
  command = plan

  variables {
    # Another account: a name would resolve in the function's own account.
    audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:111122223333:secret:shared/audit-chain-key-RLtpME"
    # A name ending in "-" plus six characters is ambiguous with an ARN suffix.
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:585192672263:secret:ops/keyring-ABC123-zDn618"
  }

  assert {
    condition = alltrue([
      local.lambda_environment["AuditLog__ChainVerification__Key"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:111122223333:secret:shared/audit-chain-key-RLtpME",
      local.lambda_environment["Operations__SecretChannel__KeyRingCertificatePkcs12"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:585192672263:secret:ops/keyring-ABC123-zDn618",
    ])
    error_message = "Cross-account or ambiguous operator secrets must keep the full ARN."
  }
}

# Anything pushing the environment past 4096 bytes is a plan-time error.
run "oversized_environment_fails_at_plan" {
  command = plan

  variables {
    additional_env = {
      HONUA_SERVE_ADMIN_UI = "true"
      HONUA_ADMIN_UI       = "true"
      HONUA_PADDING        = format("%1200s", "x")
    }
  }

  expect_failures = [aws_lambda_function.this]
}
