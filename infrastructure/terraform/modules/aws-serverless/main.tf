data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  name = "${var.name_prefix}-${var.environment}"
  tags = merge({
    Project     = "honua-server"
    Environment = var.environment
    ManagedBy   = "terraform"
  }, var.tags)
  use_existing_vpc   = var.existing_vpc_id != ""
  vpc_id             = local.use_existing_vpc ? var.existing_vpc_id : module.vpc[0].vpc_id
  vpc_cidr_block     = local.use_existing_vpc ? var.existing_vpc_cidr : module.vpc[0].vpc_cidr_block
  public_subnets     = local.use_existing_vpc ? var.existing_public_subnet_ids : module.vpc[0].public_subnets
  private_subnets    = local.use_existing_vpc ? var.existing_private_subnet_ids : module.vpc[0].private_subnets
  db_use_existing    = var.existing_db_endpoint != "" && var.existing_db_connection_string != ""
  redis_enabled      = var.redis_enabled || var.redis_connection_string != ""
  redis_create       = var.redis_enabled && var.redis_connection_string == ""
  image_ref          = split("@", var.image)[0]
  image_repo_path    = join("/", slice(split("/", local.image_ref), 1, length(split("/", local.image_ref))))
  image_repo_name    = split(":", local.image_repo_path)[0]
  image_registry     = split("/", local.image_ref)[0]
  redis_auth_token   = var.redis_auth_token != "" ? var.redis_auth_token : (local.redis_create ? random_password.redis_auth[0].result : "")
  redis_connection   = var.redis_connection_string != "" ? var.redis_connection_string : (local.redis_create ? "${aws_elasticache_replication_group.redis[0].primary_endpoint_address}:${var.redis_port},password=${local.redis_auth_token},ssl=true" : "")
  redis_egress_cidrs = local.redis_create ? [local.vpc_cidr_block] : var.redis_connection_cidrs
}

check "existing_db_inputs" {
  assert {
    condition = (
      (var.existing_db_endpoint == "" && var.existing_db_connection_string == "") ||
      (var.existing_db_endpoint != "" && var.existing_db_connection_string != "")
    )
    error_message = "existing_db_endpoint and existing_db_connection_string must both be set or both be empty."
  }
}

check "existing_vpc_inputs" {
  assert {
    condition = (
      (var.existing_vpc_id == "" && var.existing_vpc_cidr == "" && length(var.existing_public_subnet_ids) == 0 && length(var.existing_private_subnet_ids) == 0) ||
      (var.existing_vpc_id != "" && var.existing_vpc_cidr != "" && length(var.existing_public_subnet_ids) > 0 && length(var.existing_private_subnet_ids) > 0)
    )
    error_message = "existing_vpc_id, existing_vpc_cidr, existing_public_subnet_ids, and existing_private_subnet_ids must be set together."
  }
}

check "existing_redis_inputs" {
  assert {
    condition     = var.redis_connection_string == "" || length(var.redis_connection_cidrs) > 0
    error_message = "redis_connection_cidrs must include at least one trusted CIDR when redis_connection_string is set."
  }
}

resource "random_password" "db" {
  count            = var.db_password == null && !local.db_use_existing ? 1 : 0
  length           = 32
  special          = true
  override_special = "#%*()-_=+[]{}:?"
}

resource "random_password" "redis_auth" {
  count       = local.redis_create && var.redis_auth_token == "" ? 1 : 0
  length      = 32
  special     = true
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
  min_special = 1
  # ElastiCache AUTH accepts only this restricted special-character set.
  override_special = "!&#$^<>-"
}

# Connection-encryption master key. Generated independently of the admin
# password so admin-password rotation cannot break decryption and the two
# never share a value. Operators may pin it via connection_encryption_master_key.
resource "random_password" "master_key" {
  count            = var.connection_encryption_master_key == null ? 1 : 0
  length           = 32
  special          = true
  override_special = "#%*()-_=+[]{}:?"
}

locals {
  db_password     = var.db_password != null ? var.db_password : (local.db_use_existing ? "" : random_password.db[0].result)
  master_key      = var.connection_encryption_master_key != null ? var.connection_encryption_master_key : random_password.master_key[0].result
  db_ssl          = var.db_require_ssl ? ";SSL Mode=Require;Trust Server Certificate=false" : ""
  db_endpoint     = local.db_use_existing ? var.existing_db_endpoint : module.rds[0].db_instance_address
  db_conn_options = var.db_connection_string_options != "" ? ";${var.db_connection_string_options}" : ""
  # Npgsql pool bounds for the module-built connection string. Every warm Lambda
  # instance (API and control-plane) and every GP Batch job opens its own pools,
  # so the defaults (Maximum Pool Size 100, idle connections kept 300 s) let a
  # handful of warm instances exhaust a small RDS (honua-release e2e-cloud-aws
  # run 38107383082: "53300: remaining connection slots are reserved").
  #
  # These keywords bound the pools the server opens straight from the
  # configured string (for example the startup PostGIS preflight). One secret
  # serves the API, control-plane and GP Batch processes, so it carries the
  # API's cap. The server's main NpgsqlDataSource ignores them and takes its
  # bounds from Limits:Connections (local.db_pool_environment, per process).
  # db_connection_string_options comes last, so an operator keyword wins.
  db_pool_options      = ";Maximum Pool Size=${var.lambda_db_max_pool_size};Connection Idle Lifetime=${var.db_connection_idle_lifetime_seconds};Connection Pruning Interval=10;Timeout=15"
  db_connection_string = local.db_use_existing ? var.existing_db_connection_string : "Host=${local.db_endpoint};Port=5432;Database=${var.db_name};Username=${var.db_username};Password=${local.db_password}${local.db_ssl}${local.db_pool_options}${local.db_conn_options}"
  # The server's NpgsqlDataSource (PostgresDataSourceFactory) overwrites the
  # connection string's pool keywords with Limits:Connections, whose defaults
  # are MaxConnectionPoolSize 200, MinConnectionPoolSize 20 (never pruned below)
  # and ConnectionIdleLifetimeSeconds 600, so each process gets its cap through
  # the environment.
  #
  # The Lambda functions carry only the cap (Lambda 4 KB environment budget).
  # A Lambda instance is frozen between invocations, so Npgsql's idle pruning
  # barely runs there and its connections last until the instance is retired;
  # the cap is what bounds them. The GP Batch job runs continuously, has no
  # 4 KB cap, and also gets MinConnectionPoolSize 0 and the idle lifetime so a
  # long job gives back connections it no longer uses.
  # ConnectionPruningIntervalSeconds already defaults to 10.
  #
  # The server refuses to start unless MaxConcurrentQueries (default 200) is
  # at most MaxConnectionPoolSize (LimitsOptionsValidator.ValidateConnectionLimits;
  # honua-release e2e-cloud-aws run 38116311885: every Lambda exited with
  # "Invalid limits configuration: Connections.MaxConcurrentQueries must be less
  # than or equal to Connections.MaxConnectionPoolSize"), so every process sets
  # both to the same cap. The validator's other connection checks apply only
  # with AdaptiveConcurrencyEnabled (default off), and the pool factory clamps
  # MinConnectionPoolSize to the cap itself.
  #
  # Behind RDS Proxy every process also carries
  # local.db_session_settings_environment (rds-proxy.tf), which moves the
  # server's session timeouts from a per-connection SET onto the database
  # role's defaults so the proxy can multiplex instead of pinning.
  #
  # The same per-process map also carries local.import_limits_environment for
  # the API Lambda and the GP Batch job. The control-plane event functions drop
  # it with the other HTTP-only settings (control-plane-events.tf): only the
  # HTTP import endpoints read it, and those functions serve no uploads.
  db_pool_environment = {
    for process, size in {
      lambda        = var.lambda_db_max_pool_size
      control_plane = var.control_plane_db_max_pool_size
      gp_batch      = var.gp_batch_db_max_pool_size
      } : process => merge({
        Limits__Connections__MaxConnectionPoolSize = tostring(size)
        Limits__Connections__MaxConcurrentQueries  = tostring(size)
        }, process == "gp_batch" ? {
        Limits__Connections__MinConnectionPoolSize         = "0"
        Limits__Connections__ConnectionIdleLifetimeSeconds = tostring(var.db_connection_idle_lifetime_seconds)
    } : {}, local.db_session_settings_environment, local.import_limits_environment)
  }
  # Upload size (bytes) above which honua-server runs an import as a background
  # job instead of inline (Import:Limits:BackgroundJobThresholdBytes). Null
  # (default) renders nothing and keeps the server default of 100 MiB. When set
  # it wins over the same key in additional_env.
  import_limits_environment = var.import_background_job_threshold_bytes == null ? {} : {
    Import__Limits__BackgroundJobThresholdBytes = tostring(var.import_background_job_threshold_bytes)
  }
  # Shared file storage (file-storage.tf). Local, the server default, renders
  # nothing. AwsS3 renders the provider, bucket and region (the server requires
  # both) and the key prefix when one is set, on the API Lambda (and so on the
  # control-plane event functions, which start from local.lambda_environment)
  # and on every GP Batch job-definition tier.
  file_storage_shared = var.file_storage_provider == "AwsS3" && trimspace(var.file_storage_aws_s3_bucket_name) != ""
  file_storage_environment = local.file_storage_shared ? merge({
    FileStorage__Provider          = "AwsS3"
    FileStorage__AwsS3__BucketName = var.file_storage_aws_s3_bucket_name
    FileStorage__AwsS3__Region     = trimspace(var.file_storage_aws_s3_region) != "" ? var.file_storage_aws_s3_region : data.aws_region.current.name
    }, var.file_storage_aws_s3_key_prefix != "" ? {
    FileStorage__AwsS3__KeyPrefix = var.file_storage_aws_s3_key_prefix
  } : {}) : {}
  lambda_function_name = "${local.name}-honua"
  # Compute from the same provider identity/name as the function, without a
  # self-reference cycle through aws_lambda_function.this.environment.
  lambda_function_arn = "arn:${split(":", data.aws_caller_identity.current.arn)[1]}:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:${local.lambda_function_name}"
  lambda_target_id    = "${local.lambda_function_name}-${var.lambda_alias_name}"
  # SNS targets for CloudWatch alarm/OK notifications: caller-supplied topic
  # ARNs plus an optional module-created topic (when alarm_email is set).
  alarm_action_arns = concat(var.alarm_sns_topic_arns, aws_sns_topic.alarms[*].arn)
  # Redis connection is delivered via Secrets Manager indirection (matching the
  # DB connection) so the value is never a plaintext Lambda env var. The secret
  # exists whenever local.redis_connection is non-empty (redis_enabled is true).
  redis_secret_environment = local.redis_connection != "" ? {
    ConnectionStrings__redis = "aws:secretsmanager:${aws_secretsmanager_secret.redis_connection[0].arn}"
  } : {}
  # A connected Redis makes the server compose the durable operation secret
  # channel, which refuses to start without the key-ring certificate. Lambda
  # cannot resolve Secrets Manager into env the way ECS `secrets` does, so the
  # function carries an aws:secretsmanager: REFERENCE that the server resolves
  # with the function role and materializes privately at startup. Terraform
  # never reads the bundle.
  operation_key_ring_certificate_environment = local.redis_enabled && var.operation_key_ring_certificate_secret_arn != "" ? {
    Operations__SecretChannel__KeyRingCertificatePkcs12 = "aws:secretsmanager:${var.operation_key_ring_certificate_secret_arn}"
  } : {}
  # Secret/KMS grants for every Lambda role that composes the server DI from
  # local.lambda_environment. Empty when Redis is off, so Redis-off cells take
  # no dependency on the certificate.
  operation_key_ring_certificate_secret_arns  = local.redis_enabled && var.operation_key_ring_certificate_secret_arn != "" ? [var.operation_key_ring_certificate_secret_arn] : []
  operation_key_ring_certificate_kms_key_arns = local.redis_enabled && var.operation_key_ring_certificate_secret_kms_key_arn != "" ? [var.operation_key_ring_certificate_secret_kms_key_arn] : []
  # Audit hash-chain key: every process that writes audit rows (API and event
  # functions, GP Batch jobs) must carry the same key, so all of them receive
  # the same aws:secretsmanager: reference and read grant.
  audit_chain_key_environment = var.audit_chain_key_secret_arn != "" ? {
    AuditLog__ChainVerification__Key = "aws:secretsmanager:${var.audit_chain_key_secret_arn}"
  } : {}
  audit_chain_key_secret_arns  = var.audit_chain_key_secret_arn != "" ? [var.audit_chain_key_secret_arn] : []
  audit_chain_key_kms_key_arns = var.audit_chain_key_secret_arn != "" && var.audit_chain_key_secret_kms_key_arn != "" ? [var.audit_chain_key_secret_kms_key_arn] : []
  # Every secret local.lambda_environment references. The API Lambda role and the
  # control-plane event Lambda role compose the same DI from that environment,
  # so both read exactly this list; a secret granted to one but not the other
  # crashes the other at init (honua-release e2e-cloud-aws run 38066103745: the
  # event functions could not read the connection-encryption master key).
  lambda_secret_arns = concat(compact([
    local.runtime_connection_secret.arn,
    aws_secretsmanager_secret.admin_password.arn,
    aws_secretsmanager_secret.master_key.arn,
    aws_secretsmanager_secret.runtime_settings.arn,
    local.redis_enabled ? aws_secretsmanager_secret.redis_connection[0].arn : null,
    local.pro_license_effective_secret_arn
  ]), local.operation_key_ring_certificate_secret_arns, local.audit_chain_key_secret_arns)
  # Lambda environment budget: AWS Lambda rejects a function whose environment
  # (every key and value) exceeds 4 KB, and the reference VALUES dominate it. A
  # full Secrets Manager ARN costs 59 bytes more than the secret's name
  # ("arn:aws:secretsmanager:<region>:<account>:secret:" plus "-XXXXXX"), so
  # the Lambda functions carry aws:secretsmanager:<name> where that is
  # unambiguous. The server hands everything after the prefix to GetSecretValue
  # as SecretId (AwsSecretsManagerResolver, AwsSecretsManagerLicenseContentResolver)
  # and, for a non-ARN id, signs for the AWS_REGION Lambda always sets, so a
  # same-account, same-region name resolves the same secret. IAM is evaluated
  # against the secret's ARN either way, so the grants below are unchanged.
  #
  # A name is used only when it cannot be mistaken for a partial ARN: Secrets
  # Manager warns that a name ending in "-" plus six characters can be confused
  # with its random ARN suffix, so such names (e.g. "<name>/connection-string") keep the full ARN. Operator ARNs
  # are shortened only when they are in this account and region. The GP Batch
  # job definitions keep full ARNs (no 4 KB cap there).
  secret_arn_parts      = "^arn:[^:]+:secretsmanager:([^:]+):([0-9]{12}):secret:(.+)-[A-Za-z0-9]{6}$"
  ambiguous_secret_name = "-[A-Za-z0-9]{6}$"
  lambda_operator_secret_ids = {
    for arn in compact([
      var.operation_key_ring_certificate_secret_arn,
      var.audit_chain_key_secret_arn,
      (var.oidc_static_jwt == null ? "" : var.oidc_static_jwt.signing_key_secret_arn),
      local.pro_license_adopted ? trimspace(var.pro_license_secret_arn) : "",
      ]) : arn => try(
      (
        regex(local.secret_arn_parts, arn)[0] == data.aws_region.current.name &&
        regex(local.secret_arn_parts, arn)[1] == data.aws_caller_identity.current.account_id &&
        !can(regex(local.ambiguous_secret_name, regex(local.secret_arn_parts, arn)[2]))
      ) ? regex(local.secret_arn_parts, arn)[2] : arn,
      arn
    )
  }
  lambda_module_secret_ids = {
    for key, secret in merge(
      {
        connection_string = local.runtime_connection_secret
        admin_password    = aws_secretsmanager_secret.admin_password
        master_key        = aws_secretsmanager_secret.master_key
        runtime_settings  = aws_secretsmanager_secret.runtime_settings
      },
      local.redis_connection != "" ? { redis_connection = aws_secretsmanager_secret.redis_connection[0] } : {},
      local.pro_license_manage_secret ? { pro_license = aws_secretsmanager_secret.pro_license[0] } : {},
    ) : key => can(regex(local.ambiguous_secret_name, secret.name)) ? secret.arn : secret.name
  }
  # Same keys and precedence as the ARN-valued *_environment locals above, which
  # the GP Batch job definitions keep using.
  lambda_secret_reference_environment = merge(
    local.redis_connection != "" ? {
      ConnectionStrings__redis = "aws:secretsmanager:${local.lambda_module_secret_ids.redis_connection}"
    } : {},
    local.redis_enabled && var.operation_key_ring_certificate_secret_arn != "" ? {
      Operations__SecretChannel__KeyRingCertificatePkcs12 = "aws:secretsmanager:${local.lambda_operator_secret_ids[var.operation_key_ring_certificate_secret_arn]}"
    } : {},
    var.audit_chain_key_secret_arn != "" ? {
      AuditLog__ChainVerification__Key = "aws:secretsmanager:${local.lambda_operator_secret_ids[var.audit_chain_key_secret_arn]}"
    } : {},
  )
  xray_environment = var.enable_xray_tracing ? {
    Tracing__XRay__Enabled = "true"
  } : {}
  # Pro license delivered via Secrets Manager: the server resolves the ~2KB signed
  # envelope from the secret reference at startup (it does not fit Lambda's 4KB env
  # limit inline) and trusts the relabeled, hyphen-free keyId's public key.
  #
  # Ownership of the secret and of its VALUE are decoupled, because a signed
  # envelope is a credential that should not have to transit a terraform.tfvars,
  # a plan file, or state to be deployed. Three modes:
  #
  #   1. pro_license_secret_arn set  -> ADOPT. The module manages neither the
  #      secret nor its value; it only wires the reference + IAM grant. The
  #      envelope is staged out-of-band. Nothing about the license is in state,
  #      so Terraform cannot delete or rewrite it.
  #   2. pro_license_content set     -> MANAGE BOTH. The module creates
  #      <name>/license-pro and writes the envelope as its version (legacy
  #      behaviour; unchanged for existing callers).
  #   3. neither set                 -> MANAGE METADATA ONLY. The module owns the
  #      secret (typically `terraform import`ed) but writes no version, leaving
  #      the value under out-of-band control.
  #
  # In modes 1 and 3 Terraform never reads the envelope: the value is not a
  # Terraform input, so it cannot leak into state or a plan artifact.
  pro_license_enabled        = var.enable_pro_license
  pro_license_adopted        = local.pro_license_enabled && trimspace(var.pro_license_secret_arn) != ""
  pro_license_manage_secret  = local.pro_license_enabled && !local.pro_license_adopted
  pro_license_manage_version = local.pro_license_manage_secret && trimspace(var.pro_license_content) != ""
  pro_license_effective_secret_arn = (
    local.pro_license_adopted ? trimspace(var.pro_license_secret_arn) :
    local.pro_license_manage_secret ? aws_secretsmanager_secret.pro_license[0].arn :
    null
  )
  pro_license_environment = local.pro_license_enabled ? {
    Licensing__LicenseContentSecretRef                  = "aws:secretsmanager:${local.pro_license_adopted ? local.lambda_operator_secret_ids[trimspace(var.pro_license_secret_arn)] : local.lambda_module_secret_ids.pro_license}"
    "Licensing__TrustedKeys__${var.pro_license_key_id}" = var.pro_license_trusted_public_key
  } : {}
  # Licensing deployment mode (operator ruling, 2026-09-12; honua-server #4721).
  # The 2026.1 candidate ships with licensing DISABLED: no license envelope, no
  # validation, no capacity metering, and every FeatureCatalog entitlement
  # active. The mode must be DECLARED, not inferred: with no license source the
  # server's own default (Licensing__Mode=Enabled) resolves to the Community
  # edition and silently gates editing/sync/streaming/geocoding, so a candidate
  # deployed with no license inputs would look licensed-but-crippled instead of
  # licensing-disabled.
  #
  # Supplying a license (enable_pro_license) is the 2026.2 path and forces
  # Enabled, because an envelope is only meaningful to a server that loads and
  # validates it. Otherwise var.licensing_mode decides, defaulting to Disabled.
  licensing_mode = local.pro_license_enabled ? "Enabled" : var.licensing_mode
  licensing_environment = {
    Licensing__Mode = local.licensing_mode
  }
  # Allowlist for request-supplied secret references (honua-server #5055):
  # indexed Security__RequestSecretReferences__<List>__<n> entries in list order.
  # Empty lists render nothing, which keeps the server's deny-by-default policy.
  request_secret_reference_environment = merge(
    { for index, value in var.request_secret_reference_allowed_environment_variables : "Security__RequestSecretReferences__AllowedEnvironmentVariables__${index}" => value },
    { for index, value in var.request_secret_reference_allowed_environment_variable_prefixes : "Security__RequestSecretReferences__AllowedEnvironmentVariablePrefixes__${index}" => value },
    { for index, value in var.request_secret_reference_allowed_secret_reference_prefixes : "Security__RequestSecretReferences__AllowedSecretReferencePrefixes__${index}" => value },
  )
  # Studio end-user authorization (honua-server Studio:EndUserAuthorization:Enabled).
  # The server admits admins to the Studio authoring API unconditionally and other
  # authenticated principals only when this flag is on. Off renders nothing, which
  # keeps the server default (admins only).
  studio_end_user_authorization_environment = var.studio_end_user_authorization ? {
    Studio__EndUserAuthorization__Enabled = "true"
  } : {}
  # Operation policy rules (honua-server Operations:Policy:Rules). The image's
  # Production settings enable the policy with DefaultDecision Deny, so every
  # typed operation is denied until a rule allows it. Rules are first-match-wins
  # in list order and render as indexed Operations__Policy__Rules__<n>__<Field>
  # entries; unset optional fields render nothing (a wildcard on the server).
  operations_policy_environment = merge({}, [
    for index, rule in var.operations_policy_rules : {
      for field, value in {
        OperationId  = rule.operation_id
        Role         = rule.role
        Tier         = rule.tier
        Decision     = rule.decision
        Reason       = rule.reason
        ApprovalLane = rule.approval_lane
      } : "Operations__Policy__Rules__${index}__${field}" => value if value != null
    }
  ]...)
  # When GP-on-Batch is enabled, surface the DURABLE substrate to the server as a
  # ControlPlane:ExecutionWorkloads entry: the queue and the per-TIER job
  # definitions (s/m/l/xl). The reconciler selects the AwsBatchComputeBackend by
  # Backend=honua-aws-batch + TargetKind=AwsBatch, picks the size tier per job,
  # and applies vCPU/memory/timeout/retry as SubmitJob overrides at run time —
  # terraform does NOT template those per job.
  #
  # Lambda environment budget (see lambda_environment_bytes): the values are the
  # queue NAME and the job-definition NAME:REVISION, not their ARNs. The server
  # passes them to SubmitJob/ListJobs verbatim (AwsBatchComputeBackend ->
  # AwsBatchJobClient), and AWS Batch accepts a name or name:revision for a
  # same-account, same-region queue/definition, so the pinned immutable
  # revision is unchanged. The parameter KEYS keep their *_arn contract names.
  # batch.region is not emitted: the backend treats it as optional and, when
  # absent, the SDK client uses the function's own AWS_REGION, which is the
  # region the queue was created in.
  gp_batch_environment = local.gp_batch_enabled ? {
    ControlPlane__ExecutionWorkloads__0__WorkloadId                 = var.gp_batch_workload_id
    ControlPlane__ExecutionWorkloads__0__WorkloadName               = var.gp_batch_workload_name
    ControlPlane__ExecutionWorkloads__0__TargetKind                 = "AwsBatch"
    ControlPlane__ExecutionWorkloads__0__Backend                    = "honua-aws-batch"
    ControlPlane__ExecutionWorkloads__0__Kind                       = "Geoprocessing"
    ControlPlane__ExecutionWorkloads__0__ArtifactReference          = local.gp_batch_image
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__0__Key   = "batch.job_queue_arn"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__0__Value = aws_batch_job_queue.gp[0].name
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__1__Key   = "batch.job_definition_arn.s"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__1__Value = "${aws_batch_job_definition.gp["s"].name}:${aws_batch_job_definition.gp["s"].revision}"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__2__Key   = "batch.job_definition_arn.m"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__2__Value = "${aws_batch_job_definition.gp["m"].name}:${aws_batch_job_definition.gp["m"].revision}"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__3__Key   = "batch.job_definition_arn.l"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__3__Value = "${aws_batch_job_definition.gp["l"].name}:${aws_batch_job_definition.gp["l"].revision}"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__4__Key   = "batch.job_definition_arn.xl"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__4__Value = "${aws_batch_job_definition.gp["xl"].name}:${aws_batch_job_definition.gp["xl"].revision}"
  } : {}
  # Browser origins (honua-server cloud-deployments guide lists
  # Cors__AllowedOrigins__0 as required for Console/Studio). Indexed in list
  # order; an empty or null list renders nothing, so API-only cells keep the
  # server's no-CORS default. The server is the only CORS source: API Gateway
  # has no cors_configuration (see aws_apigatewayv2_api.this).
  cors_environment = { for index, origin in coalesce(var.cors_allowed_origins, []) : "Cors__AllowedOrigins__${index}" => origin }
  # API Gateway is HTTPS-only, but Lambda Web Adapter's final in-process hop is HTTP.
  # Emit HSTS for that trusted topology instead of suppressing it based on the internal scheme.
  #
  # Lambda environment budget (lambda_environment_bytes below): values equal to
  # the server's defaults are not emitted.
  # - HONUA_SKIP_MIGRATIONS is read as a bool that defaults to false (Program.cs),
  #   so it is emitted only when true.
  # - HONUA_SERVE_ADMIN_UI / HONUA_ADMIN_UI are emitted only when true (absent
  #   and "false" are the same to every reader).
  # - Deploy-target settings live in a version-pinned settings document, keeping
  #   account/region/function/alias authority explicit without consuming the
  #   environment budget with repeated ControlPlane__DeployTargets prefixes.
  lambda_environment = merge({ for i, h in local.lambda_additional_allowed_hosts : "HostValidation__AllowedHosts__${i + 1}" => h },
    var.skip_migrations ? { HONUA_SKIP_MIGRATIONS = "true" } : {},
    var.serve_admin_ui ? { HONUA_SERVE_ADMIN_UI = "true", HONUA_ADMIN_UI = "true" } : {},
    {
      HostValidation__AllowedHosts__0           = "*.execute-api.${data.aws_region.current.name}.amazonaws.com"
      SecurityHeaders__HstsHttpsOnly            = "false"
      ConnectionStrings__DefaultConnection      = "aws:secretsmanager:${local.lambda_module_secret_ids.connection_string}"
      HONUA_ADMIN_PASSWORD                      = "aws:secretsmanager:${local.lambda_module_secret_ids.admin_password}"
      Security__ConnectionEncryption__MasterKey = "aws:secretsmanager:${local.lambda_module_secret_ids.master_key}"
      HONUA_OBSERVABILITY                       = "true"
      HONUA_SETTINGS_DOCUMENT                   = "aws:secretsmanager:${local.lambda_module_secret_ids.runtime_settings}?versionId=${aws_secretsmanager_secret_version.runtime_settings.version_id}"
    }, local.gp_batch_environment, local.amazon_location_environment, local.public_base_url_environment, { for key, value in var.additional_env : key => value if var.platform_release == null || !startswith(lower(replace(key, ":", "__")), "controlplane__platformrelease__") }, local.platform_release_environment.api, local.operations_policy_environment, local.studio_end_user_authorization_environment, local.db_pool_environment.lambda, local.lambda_secret_reference_environment, local.xray_environment, local.pro_license_environment, local.licensing_environment, local.request_secret_reference_environment, local.bedrock_ai_environment, local.transcript_signing_environment, local.cors_environment, local.file_storage_environment, local.oidc_static_environment,
    var.oidc_static_jwt == null ? {} : {
      Oidc__TokenValidation__SymmetricSigningKey = "aws:secretsmanager:${local.lambda_operator_secret_ids[var.oidc_static_jwt.signing_key_secret_arn]}${var.oidc_static_jwt.signing_key_secret_version_id == "" ? "" : "?versionId=${var.oidc_static_jwt.signing_key_secret_version_id}"}"
  })

  # AWS Lambda refuses a function whose environment exceeds 4 KB ("exceeded the
  # 4KB limit. Measured size: N bytes") and only says so at CreateFunction /
  # UpdateFunctionConfiguration, after everything else has been applied. Lambda
  # measures the variables as a JSON object: every key and value plus six bytes
  # of quoting and separators per entry and the two braces. That formula
  # reproduces exactly the 4118 bytes Lambda measured for honua-release
  # e2e-cloud-aws run 38046060497 (aws-serverless/redis-on). The function
  # resources assert it at plan time.
  #
  # Some values are unknown on a first plan: a secret ARN's random suffix and a
  # job definition's revision. Their LENGTHS are known, so the estimate uses
  # same-length stand-ins (a 3-digit revision; Lambda rejects a 4 KB+ revision
  # long before revision 1000 matters), keeping the check a plan-time error.
  # The environment inherits sensitivity from the Redis inputs; a byte count
  # reveals nothing, so it is unwrapped (sensitive() first, because nonsensitive()
  # refuses an already non-sensitive value on older Terraform) for the message.
  lambda_environment_limit_bytes = 4096
  lambda_environment_size_stand_ins = merge(
    {
      HONUA_SETTINGS_DOCUMENT              = "aws:secretsmanager:${aws_secretsmanager_secret.runtime_settings.name}?versionId=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
      ConnectionStrings__DefaultConnection = "aws:secretsmanager:${can(regex(local.ambiguous_secret_name, local.runtime_connection_secret.name)) ? "arn:${split(":", data.aws_caller_identity.current.arn)[1]}:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${local.runtime_connection_secret.name}-XXXXXX" : local.runtime_connection_secret.name}"
    },
    local.gp_batch_enabled ? {
      for index, tier in ["s", "m", "l", "xl"] :
      "ControlPlane__ExecutionWorkloads__0__ParameterEntries__${index + 1}__Value" => "${aws_batch_job_definition.gp[tier].name}:000"
    } : {},
  )
  lambda_environment_bytes = {
    for function, environment in {
      api                     = local.lambda_environment
      control_plane_reconcile = local.control_plane_reconcile_environment
      control_plane_backstop  = local.control_plane_backstop_environment
      control_plane_tick      = local.control_plane_tick_environment
    } : function => nonsensitive(sensitive(sum(concat([1], [for key, value in merge(environment, local.lambda_environment_size_stand_ins) : length(key) + length(value) + 6]))))
  }
}

#checkov:skip=CKV_TF_1: Registry modules are version-pinned.
module "vpc" {
  count = local.use_existing_vpc ? 0 : 1
  #checkov:skip=CKV_TF_1: Registry modules are version-pinned.
  #checkov:skip=CKV2_AWS_12: Default SG is managed via module inputs.
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, length(var.public_subnet_cidrs))
  public_subnets  = var.public_subnet_cidrs
  private_subnets = var.private_subnet_cidrs

  enable_nat_gateway             = var.enable_nat_gateway
  single_nat_gateway             = var.single_nat_gateway
  enable_dns_support             = true
  enable_dns_hostnames           = true
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  tags = local.tags
}

locals {
  db_subnet_ids = var.db_publicly_accessible ? local.public_subnets : local.private_subnets
}

#checkov:skip=CKV2_AWS_5: Security group is attached to the Lambda function.
resource "aws_security_group" "lambda" {
  #checkov:skip=CKV2_AWS_5: Security group is attached to the Lambda function.
  name_prefix = "${local.name}-lambda-"
  description = "Lambda security group"
  vpc_id      = local.vpc_id

  egress {
    description = "PostgreSQL access"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr_block]
  }

  dynamic "egress" {
    for_each = local.db_use_existing ? [1] : []
    content {
      description = "Existing PostgreSQL access"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  dynamic "egress" {
    for_each = local.redis_enabled ? [1] : []
    content {
      description = "Redis access"
      from_port   = var.redis_port
      to_port     = var.redis_port
      protocol    = "tcp"
      cidr_blocks = local.redis_egress_cidrs
    }
  }

  egress {
    description = "Outbound HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

#checkov:skip=CKV2_AWS_5: Security group is attached to the RDS instance.
resource "aws_security_group" "rds" {
  count = local.db_use_existing ? 0 : 1
  #checkov:skip=CKV2_AWS_5: Security group is attached to the RDS instance.
  name_prefix = "${local.name}-rds-"
  description = "RDS security group"
  vpc_id      = local.vpc_id

  # No inline ingress/egress: every RDS rule is a standalone
  # aws_security_group_rule (rds_from_lambda and rds_from_cidrs below,
  # rds_from_batch in batch.tf, rds_from_batch_provisioning/execution in
  # egress-isolation.tf). Terraform does not support inline rules alongside
  # standalone rules on one group: the inline set is authoritative, so each
  # apply would strip the standalone rules and the next would re-add them.

  tags = local.tags
}

resource "aws_security_group_rule" "rds_from_lambda" {
  count                    = local.db_use_existing ? 0 : 1
  type                     = "ingress"
  description              = "PostgreSQL from Lambda"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds[0].id
  source_security_group_id = aws_security_group.lambda.id
}

resource "aws_security_group_rule" "rds_from_cidrs" {
  # Whether an existing database is used reveals nothing about its connection
  # string, and for_each refuses sensitive values.
  for_each          = nonsensitive(local.db_use_existing) ? toset([]) : toset(var.db_additional_ingress_cidrs)
  type              = "ingress"
  description       = "PostgreSQL additional CIDR ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  security_group_id = aws_security_group.rds[0].id
  cidr_blocks       = [each.value]
}

resource "aws_security_group" "redis" {
  count       = local.redis_create ? 1 : 0
  name_prefix = "${local.name}-redis-"
  description = "Redis security group"
  vpc_id      = local.vpc_id

  ingress {
    description     = "Redis from Lambda"
    from_port       = var.redis_port
    to_port         = var.redis_port
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  # GP Batch tasks share the durable Redis job store with the Lambda. Kept
  # inline (not a standalone aws_security_group_rule) because this group
  # declares inline ingress, which the provider treats as authoritative; the
  # Batch SG only references CIDRs, so there is no dependency cycle.
  dynamic "ingress" {
    for_each = local.gp_batch_enabled ? [1] : []
    content {
      description     = "Redis from GP Batch tasks"
      from_port       = var.redis_port
      to_port         = var.redis_port
      protocol        = "tcp"
      security_groups = [aws_security_group.batch[0].id]
    }
  }

  tags = local.tags
}

resource "aws_elasticache_subnet_group" "redis" {
  count       = local.redis_create ? 1 : 0
  name        = "${local.name}-redis"
  subnet_ids  = local.private_subnets
  description = "Redis subnet group"
  tags        = local.tags
}

#checkov:skip=CKV2_AWS_50: Single-node Redis is allowed for smaller environments; Multi-AZ activates when cluster count is increased.
resource "aws_elasticache_replication_group" "redis" {
  #checkov:skip=CKV2_AWS_50: Single-node Redis is allowed for smaller environments; Multi-AZ activates when cluster count is increased.
  count                      = local.redis_create ? 1 : 0
  replication_group_id       = "${local.name}-redis"
  description                = "Honua Redis"
  node_type                  = var.redis_node_type
  engine                     = "redis"
  engine_version             = var.redis_engine_version
  port                       = var.redis_port
  parameter_group_name       = var.redis_parameter_group_name
  automatic_failover_enabled = var.redis_num_cache_clusters >= 2
  multi_az_enabled           = var.redis_num_cache_clusters >= 2
  num_cache_clusters         = var.redis_num_cache_clusters
  subnet_group_name          = aws_elasticache_subnet_group.redis[0].name
  security_group_ids         = [aws_security_group.redis[0].id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = local.redis_auth_token
  apply_immediately          = true
  tags                       = local.tags

  lifecycle {
    precondition {
      condition     = var.redis_num_cache_clusters >= 1
      error_message = "redis_num_cache_clusters must be >= 1."
    }
  }
}

#checkov:skip=CKV_TF_1: Registry modules are version-pinned.
#checkov:skip=CKV_AWS_133: Backup retention is configured in this module call.
#checkov:skip=CKV_AWS_304: Secret rotation is handled outside this module.
module "rds" {
  count = local.db_use_existing ? 0 : 1
  #checkov:skip=CKV_TF_1: Registry modules are version-pinned.
  #checkov:skip=CKV_AWS_133: Backup retention is configured in this module call.
  #checkov:skip=CKV_AWS_304: Secret rotation is handled outside this module.
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier = "${local.name}-postgres"

  engine               = "postgres"
  engine_version       = var.db_engine_version
  family               = "postgres${split(".", var.db_engine_version)[0]}"
  major_engine_version = split(".", var.db_engine_version)[0]
  instance_class       = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_encrypted     = true

  # Enforce server-side TLS so the database rejects non-SSL connections,
  # matching the require_secure_transport posture of the Azure data stack and
  # the shared aws-data module.
  create_db_parameter_group = true
  parameters = [
    {
      name         = "rds.force_ssl"
      value        = "1"
      apply_method = "immediate"
    }
  ]

  db_name                     = var.db_name
  username                    = var.db_username
  password                    = local.db_password
  manage_master_user_password = false
  port                        = 5432

  vpc_security_group_ids = local.db_use_existing ? [] : [aws_security_group.rds[0].id]
  subnet_ids             = local.db_subnet_ids
  create_db_subnet_group = true

  publicly_accessible = var.db_publicly_accessible
  multi_az            = var.db_multi_az
  apply_immediately   = var.db_apply_immediately

  backup_retention_period = var.environment == "prod" ? 7 : 3
  maintenance_window      = "Sun:04:00-Sun:05:00"

  deletion_protection              = var.environment == "prod"
  skip_final_snapshot              = var.environment != "prod"
  final_snapshot_identifier_prefix = "${local.name}-postgres-final"

  tags = local.tags
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Repository-policy ownership (honua-iac #214): only an owned repository gets its
# policy written here. In reuse mode the module makes no ECR control-plane call at
# all, so a cell explicitly denied ecr:SetRepositoryPolicy on a standing
# repository can install from it without touching (or later deleting) the
# policy its owner installed.
locals {
  manage_image_repository_policy = var.image_repository_policy_mode == "owned"
  owned_image_registry           = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com"
}

data "aws_ecr_repository" "image" {
  count = local.manage_image_repository_policy ? 1 : 0
  name  = local.image_repo_name
}

data "aws_iam_policy_document" "lambda_ecr_access" {
  count = local.manage_image_repository_policy ? 1 : 0

  statement {
    sid    = "AllowLambdaImageRetrieval"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer"
    ]

    condition {
      test     = "StringLike"
      variable = "aws:sourceArn"
      values = [
        "arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:*"
      ]
    }
  }
}

resource "aws_ecr_repository_policy" "lambda_image_access" {
  count      = local.manage_image_repository_policy ? 1 : 0
  repository = data.aws_ecr_repository.image[0].name
  policy     = data.aws_iam_policy_document.lambda_ecr_access[0].json

  lifecycle {
    # SetRepositoryPolicy replaces the whole document, so an owned policy may
    # only be written on a repository in the deploying account and region. A
    # repository anywhere else belongs to someone else: consume it in reuse mode.
    precondition {
      condition     = contains([local.owned_image_registry, "${local.owned_image_registry}.cn"], local.image_registry)
      error_message = "image_repository_policy_mode = \"owned\" writes the ECR repository policy, so image must be in this account's registry (${local.owned_image_registry}); got registry \"${local.image_registry}\". Set image_repository_policy_mode = \"reuse\" to consume a shared repository whose owner already authorizes Lambda retrieval."
    }
  }
}

resource "aws_iam_role" "lambda" {
  permissions_boundary = var.permissions_boundary_arn
  name_prefix          = "${local.name}-lambda-"
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume.json
  tags                 = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_policy" "lambda_secrets" {
  name = "${local.name}-lambda-secrets"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = concat(local.lambda_secret_arns, local.oidc_signing_secret_arns)
      }
      ], length(concat(local.operation_key_ring_certificate_kms_key_arns, local.audit_chain_key_kms_key_arns, local.oidc_signing_kms_arns)) > 0 ? [{
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = concat(local.operation_key_ring_certificate_kms_key_arns, local.audit_chain_key_kms_key_arns, local.oidc_signing_kms_arns)
    }] : [])
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_secrets" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda_secrets.arn
}

# Request-supplied secret references allowlisted under Security:RequestSecretReferences
# are resolved in-process with the Lambda role. Nothing is granted while the
# list is empty.
resource "aws_iam_role_policy" "lambda_request_secret_references" {
  count = length(var.request_secret_reference_secret_arns) > 0 ? 1 : 0
  name  = "${local.name}-request-secret-references"
  role  = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.request_secret_reference_secret_arns
      }
      ], length(var.request_secret_reference_kms_key_arns) > 0 ? [{
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.request_secret_reference_kms_key_arns
    }] : [])
  })
}

#checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
resource "aws_secretsmanager_secret" "connection_string" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
  name        = "${local.name}/connection-string"
  description = "Database connection string for Honua."
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "connection_string" {
  secret_id     = aws_secretsmanager_secret.connection_string.id
  secret_string = local.db_connection_string
}

#checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
resource "aws_secretsmanager_secret" "admin_password" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
  name        = "${local.name}/admin-password"
  description = "Admin API password for Honua."
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "admin_password" {
  secret_id     = aws_secretsmanager_secret.admin_password.id
  secret_string = var.admin_password
}

#checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
resource "aws_secretsmanager_secret" "master_key" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
  name        = "${local.name}/connection-encryption-master-key"
  description = "Connection-encryption master key for Honua (independent of the admin password)."
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "master_key" {
  secret_id     = aws_secretsmanager_secret.master_key.id
  secret_string = local.master_key
}

#checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
resource "aws_secretsmanager_secret" "redis_connection" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
  count       = local.redis_enabled ? 1 : 0
  name        = "${local.name}/redis-connection"
  description = "Redis connection string for Honua."
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "redis_connection" {
  count         = local.redis_enabled ? 1 : 0
  secret_id     = aws_secretsmanager_secret.redis_connection[0].id
  secret_string = local.redis_connection
}

# Pro license envelope. Stored in a dedicated secret (rather than inline env) so the
# ~2KB signed envelope does not consume Lambda's 4KB total-env budget; the server
# resolves it via Licensing__LicenseContentSecretRef=aws:secretsmanager:<arn> at
# startup. The envelope must carry the relabeled, hyphen-free keyId (pro_license_key_id)
# so the matching Licensing__TrustedKeys__<keyId> env var name is legal.
#
# Not created when pro_license_secret_arn is set: that secret already exists and is
# managed out-of-band, so the module adopts it by reference only (see locals).
#checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module; the license is rotated by re-issuing the envelope.
resource "aws_secretsmanager_secret" "pro_license" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module; the license is rotated by re-issuing the envelope.
  count       = local.pro_license_manage_secret ? 1 : 0
  name        = "${local.name}/license-pro"
  description = "Signed Honua Pro license envelope (resolved at startup via Licensing__LicenseContentSecretRef)."
  tags        = local.tags
}

# Only created when the caller hands Terraform the envelope (pro_license_content).
# When the value is managed outside Terraform this is count 0, so an apply never
# rewrites — or even reads — the staged envelope.
resource "aws_secretsmanager_secret_version" "pro_license" {
  count         = local.pro_license_manage_version ? 1 : 0
  secret_id     = aws_secretsmanager_secret.pro_license[0].id
  secret_string = var.pro_license_content
}

#checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
#checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
resource "aws_cloudwatch_log_group" "lambda" {
  #checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
  #checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
  name              = "/aws/lambda/${local.name}-honua"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

#checkov:skip=CKV_AWS_50: X-Ray tracing is optional and can be enabled by the deployment environment.
#checkov:skip=CKV_AWS_116: DLQ wiring is environment-specific and not required for every deployment target.
#checkov:skip=CKV_AWS_173: Secrets are injected through Secrets Manager references rather than plaintext environment values.
#checkov:skip=CKV_AWS_272: Code signing is optional for private image-based deployments.
resource "aws_lambda_function" "this" {
  #checkov:skip=CKV_AWS_50: X-Ray tracing is optional and can be enabled by the deployment environment.
  #checkov:skip=CKV_AWS_116: DLQ wiring is environment-specific and not required for every deployment target.
  #checkov:skip=CKV_AWS_173: Secrets are injected through Secrets Manager references rather than plaintext environment values.
  #checkov:skip=CKV_AWS_272: Code signing is optional for private image-based deployments.
  function_name = local.lambda_function_name
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = var.image
  publish       = true

  memory_size = var.lambda_memory_size
  timeout     = var.lambda_timeout_seconds

  architectures = var.lambda_architectures

  ephemeral_storage {
    size = var.lambda_ephemeral_storage_mb
  }

  reserved_concurrent_executions = var.lambda_reserved_concurrent_executions

  vpc_config {
    subnet_ids         = local.private_subnets
    security_group_ids = [aws_security_group.lambda.id]
  }

  dynamic "tracing_config" {
    for_each = var.enable_xray_tracing ? [1] : []
    content {
      mode = "Active"
    }
  }

  environment {
    variables = local.lambda_environment
  }

  lifecycle {
    precondition {
      condition     = var.db_max_allocated_storage >= var.db_allocated_storage
      error_message = "db_max_allocated_storage must be >= db_allocated_storage."
    }

    precondition {
      condition     = local.lambda_environment_bytes.api <= local.lambda_environment_limit_bytes
      error_message = "The ${local.lambda_function_name} environment would be about ${local.lambda_environment_bytes.api} bytes; AWS Lambda refuses more than ${local.lambda_environment_limit_bytes}. Turn off an optional feature that adds variables (Bedrock AI, Amazon Location geocoding, CORS origins, the custom domain / public_base_url, request-secret allowlists, operations_policy_rules, studio_end_user_authorization, file_storage_provider=AwsS3, additional_env, additional_allowed_hosts) or shorten name_prefix/environment."
    }

    precondition {
      condition     = var.file_storage_provider != "AwsS3" || local.file_storage_shared
      error_message = "file_storage_provider=AwsS3 requires file_storage_aws_s3_bucket_name."
    }

    precondition {
      condition     = !local.redis_enabled || var.operation_key_ring_certificate_secret_arn != ""
      error_message = "Redis-backed Production functions require operation_key_ring_certificate_secret_arn: supply an existing operator-owned Secrets Manager PKCS#12 bundle with a private key (base64 or JSON {pkcs12,password}); the module passes only its aws:secretsmanager: reference and grants the function role read access. Terraform must not receive private-key material. Without it the server refuses to start whenever Redis is connected."
    }
  }

  depends_on = [
    aws_ecr_repository_policy.lambda_image_access,
    aws_cloudwatch_log_group.lambda,
    aws_security_group_rule.rds_from_lambda,
    aws_security_group_rule.rds_proxy_from_clients,
    aws_db_proxy_target.this,
    aws_secretsmanager_secret_version.connection_string,
    aws_secretsmanager_secret_version.proxy_connection_string,
    # role-defaults mode: start no client before the role carries its defaults.
    null_resource.db_role_session_defaults,
    aws_secretsmanager_secret_version.admin_password,
    aws_secretsmanager_secret_version.master_key,
    aws_secretsmanager_secret_version.runtime_settings,
    aws_secretsmanager_secret_version.redis_connection,
    aws_secretsmanager_secret_version.pro_license,
    aws_iam_role_policy.transcript_signing,
    terraform_data.transcript_signing_validation
  ]

  tags = local.tags
}

# Fail the plan early (rather than at runtime) when the Pro license is enabled but
# misconfigured.
#
# There is deliberately NO precondition requiring pro_license_content: an empty
# envelope means "the value is managed outside Terraform", which is a supported and
# preferred delivery mode. The trusted public key IS required in every mode — it is
# not a secret (it only verifies a signature), it is safe in config, and without it
# the server cannot validate the envelope and silently falls back to Community.
resource "terraform_data" "pro_license_validation" {
  count = local.pro_license_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = trimspace(var.pro_license_trusted_public_key) != ""
      error_message = "enable_pro_license is true but pro_license_trusted_public_key (the Ed25519 public key) is empty. The public key is required in every delivery mode; it is not secret and is safe to set in config."
    }
    precondition {
      condition     = !(local.pro_license_adopted && trimspace(var.pro_license_content) != "")
      error_message = "pro_license_secret_arn and pro_license_content are mutually exclusive: pro_license_secret_arn adopts a secret whose value is managed outside Terraform, so Terraform must not also be handed the envelope. Supply exactly one."
    }
  }
}

resource "aws_lambda_alias" "live" {
  name             = var.lambda_alias_name
  description      = "Stable Honua deploy alias managed by the control plane."
  function_name    = aws_lambda_function.this.function_name
  function_version = coalesce(var.lambda_alias_version, aws_lambda_function.this.version)
}

#checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
#checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
resource "aws_cloudwatch_log_group" "api_gateway" {
  #checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
  #checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
  name              = "/aws/apigateway/${local.name}-honua"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

# No cors_configuration: honua-server is the single CORS source, as on ECS.
# With gateway CORS configured, API Gateway answers every OPTIONS preflight
# itself and replaces the integration's CORS response headers with its own, so
# the server's policy (all methods it serves incl. PATCH/HEAD, its allowed and
# exposed headers, Cors:AllowCredentials) never reaches the browser. Without it,
# preflights match the ANY / and ANY /{proxy+} routes below (ANY includes
# OPTIONS, and the routes have no authorizer), reach the Lambda, and the
# server's CORS middleware answers them from Cors__AllowedOrigins__<n>.
resource "aws_apigatewayv2_api" "this" {
  name          = "${local.name}-honua"
  protocol_type = "HTTP"

  tags = local.tags
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_alias.live.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = min(30000, var.lambda_timeout_seconds * 1000)
}

#checkov:skip=CKV_AWS_309: API Gateway intentionally forwards both public and authenticated traffic to Honua for in-app authorization.
resource "aws_apigatewayv2_route" "root" {
  #checkov:skip=CKV_AWS_309: API Gateway intentionally forwards both public and authenticated traffic to Honua for in-app authorization.
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

#checkov:skip=CKV_AWS_309: API Gateway intentionally forwards both public and authenticated traffic to Honua for in-app authorization.
resource "aws_apigatewayv2_route" "proxy" {
  #checkov:skip=CKV_AWS_309: API Gateway intentionally forwards both public and authenticated traffic to Honua for in-app authorization.
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  # Create the initial auto-deployment only after both routes exist. Without
  # this dependency, the stage may briefly publish an empty route table and
  # return API Gateway 404s immediately after terraform apply completes.
  depends_on = [
    aws_apigatewayv2_route.root,
    aws_apigatewayv2_route.proxy,
  ]

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      sourceIp       = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      path           = "$context.path"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      # Why a request failed between API Gateway and the Lambda (an init crash,
      # a timeout, a throttle) rather than only that it returned 5xx.
      integrationStatus       = "$context.integrationStatus"
      integrationErrorMessage = "$context.integrationErrorMessage"
      errorMessage            = "$context.error.message"
    })
  }

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = var.api_throttle_burst_limit
    throttling_rate_limit    = var.api_throttle_rate_limit
  }

  tags = local.tags
}

# Optional SNS topic for alarm notifications. Created only when alarm_email is
# set; operators may instead pass pre-existing topic ARNs via alarm_sns_topic_arns.
#checkov:skip=CKV_AWS_26: Alarm notifications carry non-sensitive operational metadata; KMS encryption is optional and caller-configurable.
resource "aws_sns_topic" "alarms" {
  #checkov:skip=CKV_AWS_26: Alarm notifications carry non-sensitive operational metadata; KMS encryption is optional and caller-configurable.
  count = var.alarm_email != "" ? 1 : 0
  name  = "${local.name}-alarms"
  tags  = local.tags
}

resource "aws_sns_topic_subscription" "alarms_email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Lambda function error rate is elevated."
  dimensions = {
    FunctionName = aws_lambda_function.this.function_name
  }
  alarm_actions = local.alarm_action_arns
  ok_actions    = local.alarm_action_arns
  tags          = local.tags
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.name}-api-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "5xx"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "API Gateway 5xx error rate is elevated."
  dimensions = {
    ApiId = aws_apigatewayv2_api.this.id
  }
  alarm_actions = local.alarm_action_arns
  ok_actions    = local.alarm_action_arns
  tags          = local.tags
}

# GeoServices in-band errors (HTTP 200 with an error envelope) are invisible to
# AWS/Lambda Errors and the API Gateway 5xx metric. The server logs them; this
# metric filter projects those log lines into a custom CloudWatch metric so the
# alarm below can page the same SNS targets as the other alarms.
resource "aws_cloudwatch_log_metric_filter" "geoservices_errors" {
  count          = var.geoservices_error_alarm_enabled ? 1 : 0
  name           = "${local.name}-geoservices-errors"
  log_group_name = aws_cloudwatch_log_group.lambda.name
  pattern        = var.geoservices_error_log_pattern

  metric_transformation {
    name          = "GeoServicesErrors"
    namespace     = "Honua/${local.name}"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "geoservices_errors" {
  count               = var.geoservices_error_alarm_enabled ? 1 : 0
  alarm_name          = "${local.name}-geoservices-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.geoservices_error_alarm_evaluation_periods
  metric_name         = aws_cloudwatch_log_metric_filter.geoservices_errors[0].metric_transformation[0].name
  namespace           = aws_cloudwatch_log_metric_filter.geoservices_errors[0].metric_transformation[0].namespace
  period              = var.geoservices_error_alarm_period
  statistic           = "Sum"
  threshold           = var.geoservices_error_alarm_threshold
  treat_missing_data  = "notBreaching"
  alarm_description   = "GeoServices in-band error responses (HTTP 200 with error envelope) are elevated."
  alarm_actions       = local.alarm_action_arns
  ok_actions          = local.alarm_action_arns
  tags                = local.tags
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  qualifier     = aws_lambda_alias.live.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

resource "null_resource" "enable_postgis" {
  count = var.enable_postgis && !local.db_use_existing ? 1 : 0

  triggers = {
    db_endpoint = local.db_endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "Waiting for PostgreSQL readiness on ${local.db_endpoint}"
      for attempt in $(seq 1 ${var.postgis_readiness_max_attempts}); do
        if PGCONNECT_TIMEOUT=5 psql \
          --host=${local.db_endpoint} \
          --username=${var.db_username} \
          --dbname=${var.db_name} \
          --command="SELECT 1;" >/dev/null 2>&1; then
          echo "PostgreSQL readiness check succeeded after $attempt attempt(s)"
          break
        fi
        if [ "$attempt" -eq ${var.postgis_readiness_max_attempts} ]; then
          echo "PostgreSQL readiness check failed after ${var.postgis_readiness_max_attempts} attempts" >&2
          PGCONNECT_TIMEOUT=5 psql \
            --host=${local.db_endpoint} \
            --username=${var.db_username} \
            --dbname=${var.db_name} \
            --command="SELECT 1;" >&2 || true
          exit 1
        fi
        sleep ${var.postgis_readiness_sleep_seconds}
      done

      echo "Enabling PostGIS + PostGIS Raster on ${local.db_endpoint}"
      PGCONNECT_TIMEOUT=5 psql \
        --host=${local.db_endpoint} \
        --username=${var.db_username} \
        --dbname=${var.db_name} \
        --set=ON_ERROR_STOP=1 \
        --command="CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS postgis_raster;"
    EOT
    environment = {
      PGPASSWORD = local.db_password
    }
  }

  # The runner reaches the database through the additional CIDR rules, which
  # are standalone resources rather than part of the RDS security group.
  depends_on = [module.rds, aws_security_group_rule.rds_from_cidrs]
}

# --- Role session defaults behind RDS Proxy ----------------------------------
# Behind the proxy the server processes run with
# Database__SessionSettings__Mode=role-defaults (rds-proxy.tf, Pinning): they
# issue no per-connection SET, so PostgreSQL must supply the session timeouts
# as defaults of the database role. honua-server verifies them at startup and
# only logs (event 5870) the ALTER ROLE statements when they are missing; it
# never runs ALTER ROLE itself (honua-server #5874), so the module does, once,
# as the master user on the DIRECT endpoint (the runner's CIDR is admitted on
# the RDS security group only, like null_resource.enable_postgis).
#
# The values are what the server's connection mode would SET: its
# Limits:Connections LockTimeout 30 s, StatementTimeout 30 s and
# IdleInTransactionTimeout 60 s (honua-server LimitsOptions.cs, ConnectionLimits
# defaults). The module sets none of Limits__Connections__LockTimeout /
# StatementTimeout / IdleInTransactionTimeout, so the server defaults are the
# effective values; check "db_role_session_defaults_match" flags an
# additional_env override that would make them drift. The server compares
# whole seconds.
#
# Like enable_postgis this needs psql on the machine running Terraform and a
# route to the instance, so it follows enable_postgis unless
# rds_proxy_set_role_session_defaults says otherwise. When the module does not
# run them, the rds_proxy_role_session_defaults_sql output carries the
# statements for the operator.
#
# The defaults apply to every session of the role, including the direct
# migration, seeding and operator sessions, which can override them with their
# own SET (for example SET statement_timeout = 0 for a long migration). When the
# resource is destroyed (enable_rds_proxy turned off, or before a re-run on a
# change) a destroy-time provisioner RESETs the three settings, so the role
# returns to the instance defaults; it continues on failure, so an unreachable
# instance (teardown) never blocks destroy.
#
# ALTER ROLE ... SET applies to sessions that start afterwards. The proxy
# target and every Lambda function depend on this resource, so a new
# deployment (or an upgrade that adds role-defaults mode) starts no proxied
# client before the defaults exist. When the values change later (or the
# proxy is turned on for an existing deployment), backends the proxy already
# holds keep their old settings until the proxy retires them: idle ones above
# rds_proxy_max_idle_connections_percent close, and a pinned backend closes
# with its client (rds_proxy_idle_client_timeout_seconds). See the README.
locals {
  db_role_session_defaults_enabled = coalesce(var.rds_proxy_set_role_session_defaults, var.enable_postgis)
  db_role_session_settings = {
    lock_timeout                        = "30s"
    statement_timeout                   = "30s"
    idle_in_transaction_session_timeout = "60s"
  }
  db_role_session_settings_sql = join("\n", [
    for setting, value in local.db_role_session_settings :
    "ALTER ROLE \"${replace(var.db_username, "\"", "\"\"")}\" SET ${setting} = '${value}';"
  ])
  db_role_session_settings_reset_sql = join("\n", [
    for setting, value in local.db_role_session_settings :
    "ALTER ROLE \"${replace(var.db_username, "\"", "\"\"")}\" RESET ${setting};"
  ])
}

resource "null_resource" "db_role_session_defaults" {
  count = local.rds_proxy_enabled && !local.db_use_existing && local.db_role_session_defaults_enabled ? 1 : 0

  # A destroy-time provisioner can read only self, so the triggers carry what
  # the RESET needs. db_password is sensitive (Terraform redacts the triggers
  # in plans) and already in state through the RDS instance and the
  # connection-string secret.
  triggers = {
    db_endpoint      = local.db_endpoint
    db_name          = var.db_name
    db_username      = var.db_username
    db_password      = local.db_password
    statements       = local.db_role_session_settings_sql
    reset_statements = local.db_role_session_settings_reset_sql
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "Waiting for PostgreSQL readiness on ${local.db_endpoint}"
      for attempt in $(seq 1 ${var.postgis_readiness_max_attempts}); do
        if PGCONNECT_TIMEOUT=5 psql \
          --host=${local.db_endpoint} \
          --username=${var.db_username} \
          --dbname=${var.db_name} \
          --command="SELECT 1;" >/dev/null 2>&1; then
          break
        fi
        if [ "$attempt" -eq ${var.postgis_readiness_max_attempts} ]; then
          echo "PostgreSQL readiness check failed after ${var.postgis_readiness_max_attempts} attempts" >&2
          exit 1
        fi
        sleep ${var.postgis_readiness_sleep_seconds}
      done

      echo "Setting the session defaults of role ${var.db_username} for RDS Proxy multiplexing"
      PGCONNECT_TIMEOUT=5 psql \
        --host=${local.db_endpoint} \
        --username=${var.db_username} \
        --dbname=${var.db_name} \
        --set=ON_ERROR_STOP=1 <<'SQL'
      ${local.db_role_session_settings_sql}
      SQL
    EOT
    environment = {
      PGPASSWORD = local.db_password
    }
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "Resetting the session defaults of role ${self.triggers.db_username}"
      PGCONNECT_TIMEOUT=5 psql \
        --host=${self.triggers.db_endpoint} \
        --username=${self.triggers.db_username} \
        --dbname=${self.triggers.db_name} \
        --set=ON_ERROR_STOP=1 <<'SQL'
      ${self.triggers.reset_statements}
      SQL
    EOT
    environment = {
      PGPASSWORD = self.triggers.db_password
    }
  }

  depends_on = [module.rds, aws_security_group_rule.rds_from_cidrs, null_resource.enable_postgis]
}

# The role defaults reproduce the server's default Limits:Connections timeouts
# and no search_path. Overriding those through additional_env behind the proxy
# makes the server's startup verification report drift (event 5870).
check "db_role_session_defaults_match" {
  assert {
    condition = !local.rds_proxy_enabled || length(setintersection(
      toset([for name in keys(var.additional_env) : lower(replace(name, ":", "__"))]),
      toset([
        "limits__connections__locktimeout",
        "limits__connections__statementtimeout",
        "limits__connections__idleintransactiontimeout",
        "database__schema",
      ])
    )) == 0
    error_message = "Behind RDS Proxy the module sets the database role's session defaults to the server's default timeouts (lock_timeout 30s, statement_timeout 30s, idle_in_transaction_session_timeout 60s) and no search_path. additional_env overrides Limits__Connections__LockTimeout / StatementTimeout / IdleInTransactionTimeout or Database__Schema, so honua-server (Database:SessionSettings:Mode=role-defaults) will report drift; run the ALTER ROLE statements it logs (event 5870)."
  }

}

check "audit_chain_key_configured" {
  assert {
    condition     = var.audit_chain_key_secret_arn != ""
    error_message = "audit_chain_key_secret_arn is empty: audit rows are still written, but scheduled hash-chain verification cannot succeed and the server's audit-chain-integrity health check reports Unhealthy. Supply an operator-owned Secrets Manager secret holding a base64 key of at least 32 bytes (set it at first install; see the module README for activating it on a deployment that already has audit rows)."
  }
}
