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

# The same release cell on its per-run HTTPS name, and on a long customer
# domain: the custom domain adds a HostValidation entry and Public__BaseUrl
# (honua-io/honua-release#450). Both must keep the 256-byte margin.
run "release_redis_on_cell_with_custom_domain_fits_with_margin" {
  command = plan

  override_resource {
    target          = aws_acm_certificate.api[0]
    override_during = plan
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
    domain_name     = "honuarawsse380460-aws-serverless-redis-on.cert.demo.honua.io"
    route53_zone_id = "Z089181827C9GKIKHXUTT"
  }

  assert {
    condition     = local.lambda_environment["Public__BaseUrl"] == "https://honuarawsse380460-aws-serverless-redis-on.cert.demo.honua.io"
    error_message = "The custom domain must render Public__BaseUrl."
  }

  assert {
    condition     = local.lambda_environment_bytes.api <= 4096 - 256
    error_message = "With the custom domain the release cell's Lambda environment is about ${local.lambda_environment_bytes.api} bytes; it must stay at least 256 bytes under 4096."
  }
}

run "release_redis_on_cell_on_a_long_customer_domain_fits" {
  command = plan

  override_resource {
    target          = aws_acm_certificate.api[0]
    override_during = plan
    values = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [{
        domain_name           = "geospatial-services.public-works.city-of-example.gov.au"
        resource_record_name  = "_abc.geospatial-services.public-works.city-of-example.gov.au."
        resource_record_type  = "CNAME"
        resource_record_value = "_def.acm-validations.aws."
      }]
    }
  }

  variables {
    domain_name     = "geospatial-services.public-works.city-of-example.gov.au"
    route53_zone_id = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition     = local.lambda_environment_bytes.api <= 4096 - 256
    error_message = "On a long customer domain the release cell's Lambda environment is about ${local.lambda_environment_bytes.api} bytes; it must stay at least 256 bytes under 4096."
  }
}

# Exercise the complete optional-feature combination with the pinned settings
# document. Preserve the previous required margins as configuration grows.
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
      ] : nonsensitive(sum([for k, v in env : length(k) + length(v) + 6]) + 1) <= 4096 - 16
    ])
    error_message = "With every optional feature on, each Lambda environment must stay at least 16 bytes under 4096 (API ${nonsensitive(sum([for k, v in aws_lambda_function.this.environment[0].variables : length(k) + length(v) + 6]) + 1)}, scheduled-tick ${nonsensitive(sum([for k, v in aws_lambda_function.control_plane_tick[0].environment[0].variables : length(k) + length(v) + 6]) + 1)} bytes)."
  }
}

# The same with RDS Proxy (honua-release run 38163689854): the proxy adds
# Database__SessionSettings__Mode=role-defaults (50 bytes) to every function,
# and the proxy connection-string secret is referenced by its shorter name, so
# the scheduled-tick function measures 4070 bytes, still under the margin.
run "every_optional_feature_with_rds_proxy_fits" {
  command = apply

  # The mock provider generates a random name, which aws_db_proxy_target
  # rejects when it starts with a digit; pin the real default name.
  override_resource {
    target = aws_db_proxy_default_target_group.this[0]
    values = { name = "default" }
  }

  variables {
    enable_rds_proxy                                               = true
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
      ] : lookup(env, "Database__SessionSettings__Mode", null) == "role-defaults" && nonsensitive(sum([for k, v in env : length(k) + length(v) + 6]) + 1) <= 4096 - 16
    ])
    error_message = "With RDS Proxy and every optional feature on, each Lambda environment must carry the role-defaults mode and stay at least 16 bytes under 4096 (API ${nonsensitive(sum([for k, v in aws_lambda_function.this.environment[0].variables : length(k) + length(v) + 6]) + 1)}, scheduled-tick ${nonsensitive(sum([for k, v in aws_lambda_function.control_plane_tick[0].environment[0].variables : length(k) + length(v) + 6]) + 1)} bytes)."
  }
}

# Moving the registry out of the environment also makes this previously
# oversized combination viable. The explicit oversized fixture below still
# verifies that the hard limit fails at plan time.
run "pro_license_on_top_of_every_feature_fits" {
  command = apply

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

  assert {
    condition = alltrue([
      for env in [
        aws_lambda_function.this.environment[0].variables,
        aws_lambda_function.control_plane_reconcile[0].environment[0].variables,
        aws_lambda_function.control_plane_backstop[0].environment[0].variables,
        aws_lambda_function.control_plane_tick[0].environment[0].variables,
      ] : nonsensitive(sum([for k, v in env : length(k) + length(v) + 6]) + 1) <= 4096 - 16
    ])
    error_message = "The Pro combination must fit the unchanged 4 KB limit with at least 16 bytes of headroom on every function."
  }
}

# Shared S3 file storage (file_storage_provider = AwsS3) adds FileStorage__Provider,
# __AwsS3__BucketName, __AwsS3__Region and __AwsS3__KeyPrefix: 214 bytes with the
# release bucket and the harness prefix release-cells/<name_prefix>. This is the
# full release Redis-on cell (key ring, audit key, GP Batch, control-plane events,
# the import threshold, one CORS origin, Studio end-user authorization, the two
# release operation policy rules and the per-run custom domain) with it on. The
# control-plane event functions carry no HTTP-serving settings
# (control-plane-events.tf), which keeps them under the cap with the margin.
run "release_cell_with_shared_file_storage_fits" {
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
    enable_control_plane_events           = true
    import_background_job_threshold_bytes = 67108864
    cors_allowed_origins                  = ["http://127.0.0.1:18099"]
    studio_end_user_authorization         = true
    operations_policy_rules = [
      { operation_id = "*", role = "scoped-admin-key", decision = "Allow", reason = "Release cell: scoped admin keys run typed operations" },
      { operation_id = "*", role = "admin", decision = "Allow", reason = "Release cell: bootstrap and full admins run typed operations" },
    ]
    domain_name                     = "honuarawsse380460-aws-serverless-redis-on.cert.demo.honua.io"
    route53_zone_id                 = "Z089181827C9GKIKHXUTT"
    file_storage_provider           = "AwsS3"
    file_storage_aws_s3_bucket_name = "release-cells-file-storage-585192672263"
    file_storage_aws_s3_key_prefix  = "release-cells/honuarawsse380460"
  }

  assert {
    condition     = nonsensitive(sum([for k, v in aws_lambda_function.this.environment[0].variables : length(k) + length(v) + 6]) + 1) <= 4096
    error_message = "With shared file storage the release cell's API function environment is ${nonsensitive(sum([for k, v in aws_lambda_function.this.environment[0].variables : length(k) + length(v) + 6]) + 1)} bytes; Lambda refuses more than 4096."
  }

  assert {
    condition = alltrue([
      for env in [
        aws_lambda_function.control_plane_reconcile[0].environment[0].variables,
        aws_lambda_function.control_plane_backstop[0].environment[0].variables,
        aws_lambda_function.control_plane_tick[0].environment[0].variables,
      ] : nonsensitive(sum([for k, v in env : length(k) + length(v) + 6]) + 1) <= 4096 - 256
    ])
    error_message = "With shared file storage each control-plane event function must stay at least 256 bytes under 4096 (reconcile ${nonsensitive(sum([for k, v in aws_lambda_function.control_plane_reconcile[0].environment[0].variables : length(k) + length(v) + 6]) + 1)}, backstop ${nonsensitive(sum([for k, v in aws_lambda_function.control_plane_backstop[0].environment[0].variables : length(k) + length(v) + 6]) + 1)}, tick ${nonsensitive(sum([for k, v in aws_lambda_function.control_plane_tick[0].environment[0].variables : length(k) + length(v) + 6]) + 1)} bytes)."
  }

  # HTTP-serving settings stay on the API function and off the event functions.
  assert {
    condition = alltrue(concat(
      [for k in ["HostValidation__AllowedHosts__0", "HostValidation__AllowedHosts__1", "Cors__AllowedOrigins__0", "SecurityHeaders__HstsHttpsOnly", "HONUA_SERVE_ADMIN_UI", "HONUA_ADMIN_UI"] : contains(keys(aws_lambda_function.this.environment[0].variables), k)],
      flatten([
        for env in [
          aws_lambda_function.control_plane_reconcile[0].environment[0].variables,
          aws_lambda_function.control_plane_backstop[0].environment[0].variables,
          aws_lambda_function.control_plane_tick[0].environment[0].variables,
        ] : [for k in keys(env) : !(startswith(k, "HostValidation__AllowedHosts__") || startswith(k, "Cors__AllowedOrigins__") || contains(["SecurityHeaders__HstsHttpsOnly", "HONUA_SERVE_ADMIN_UI", "HONUA_ADMIN_UI"], k))]
      ]),
    ))
    error_message = "The API function must keep the HTTP-serving settings and the control-plane event functions must carry none of them."
  }
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
      # This value alone fills the AWS budget; the required keys must push it
      # over regardless of how much ordinary configuration moves to a document.
      HONUA_PADDING = format("%4096s", "x")
    }
  }

  expect_failures = [aws_lambda_function.this]
}
