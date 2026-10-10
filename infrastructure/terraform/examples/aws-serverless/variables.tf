variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name used in resource naming."
  type        = string
  default     = "it"
}

variable "name_prefix" {
  description = "Prefix used for resource names."
  type        = string
  default     = "honuasl"
}

variable "existing_vpc_id" {
  description = "Existing VPC ID to reuse."
  type        = string
  default     = ""
}

variable "existing_vpc_cidr" {
  description = "CIDR for existing_vpc_id."
  type        = string
  default     = ""
}

variable "existing_public_subnet_ids" {
  description = "Public subnet IDs in existing_vpc_id."
  type        = list(string)
  default     = []
}

variable "existing_private_subnet_ids" {
  description = "Private subnet IDs in existing_vpc_id."
  type        = list(string)
  default     = []
}

variable "honua_admin_password" {
  description = "Admin API password for Honua."
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "PostgreSQL admin password used for deterministic integration tests."
  type        = string
  sensitive   = true
  default     = null
}

variable "existing_db_endpoint" {
  description = "Existing PostgreSQL endpoint to reuse."
  type        = string
  default     = ""
}

variable "existing_db_connection_string" {
  description = "Existing PostgreSQL connection string to reuse."
  type        = string
  sensitive   = true
  default     = ""
}

variable "honua_image_uri" {
  description = "ECR image URI for Honua Lambda image (`*-lambda-aot` preferred; `*-lambda` debug fallback)."
  type        = string
}

variable "image_repository_policy_mode" {
  description = "\"owned\" (default) installs the Lambda retrieval policy on honua_image_uri's repository, which must be in this account and region. \"reuse\" consumes a shared repository whose owner already authorizes Lambda retrieval and never reads, writes or deletes its policy; certification cells installing from the standing honua-server repository must use reuse."
  type        = string
  default     = "owned"
  nullable    = false
}

variable "lambda_architectures" {
  description = "Lambda architectures. Defaults to x86_64, the architecture the 2026.1 platform manifest pins for Lambda (awsLambdaArchitecture: x86_64). Set [\"arm64\"] only with an independently verified arm64 image."
  type        = list(string)
  default     = ["x86_64"]
}

variable "lambda_alias_name" {
  description = "Stable Lambda alias used by API Gateway."
  type        = string
  default     = "live"
}

variable "lambda_alias_version" {
  description = "Optional published Lambda version to pin the stable alias to."
  type        = string
  default     = null
}

variable "db_publicly_accessible" {
  description = "Expose RDS publicly for integration testing."
  type        = bool
  default     = false
}

variable "db_additional_ingress_cidrs" {
  description = "Extra CIDRs allowed to connect to Postgres."
  type        = list(string)
  default     = []
}

variable "enable_postgis" {
  description = "Enable PostGIS and PostGIS Raster during apply."
  type        = bool
  default     = true
}

variable "postgis_readiness_max_attempts" {
  description = "Maximum readiness attempts before PostGIS enablement fails."
  type        = number
  default     = 90
}

variable "postgis_readiness_sleep_seconds" {
  description = "Seconds to sleep between PostgreSQL readiness attempts."
  type        = number
  default     = 10
}

variable "audit_chain_key_secret_kms_key_arn" {
  description = "Customer-managed KMS key ARN encrypting the audit-chain key secret. Leave empty for the AWS-managed aws/secretsmanager key."
  type        = string
  default     = ""
  nullable    = false
}

variable "audit_chain_key_secret_arn" {
  description = "ARN of an existing operator-owned Secrets Manager secret holding the base64 audit hash-chain key (at least 32 decoded bytes). Recommended for Production; the module validates the ARN. Never pass the key itself in tfvars."
  type        = string
  default     = ""
  nullable    = false
}

variable "operation_key_ring_certificate_secret_kms_key_arn" {
  description = "Customer-managed KMS key ARN encrypting the operation key-ring certificate secret. Leave empty for the AWS-managed aws/secretsmanager key. Granted to the Lambda roles only when Redis is configured."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.operation_key_ring_certificate_secret_kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.operation_key_ring_certificate_secret_kms_key_arn))
    error_message = "operation_key_ring_certificate_secret_kms_key_arn must be an exact KMS key ARN or empty."
  }
}

variable "operation_key_ring_certificate_secret_arn" {
  description = "ARN of an existing operator-owned Secrets Manager secret containing base64 PKCS#12 or a JSON {pkcs12,password} bundle with a private key. Required for Redis, including an existing Redis connection. Only the ARN enters Terraform: the Lambda receives an aws:secretsmanager: reference that the server resolves at startup with the function role. Never pass certificate material in tfvars or environment values."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.operation_key_ring_certificate_secret_arn == "" || can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", var.operation_key_ring_certificate_secret_arn))
    error_message = "operation_key_ring_certificate_secret_arn must be a complete Secrets Manager secret ARN (including its six-character suffix), not PKCS#12 material, a wildcard, or a JSON-key selector."
  }
}

variable "redis_enabled" {
  description = "Provision ElastiCache Redis."
  type        = bool
  default     = true
}

variable "redis_connection_string" {
  description = "Existing Redis connection string to reuse."
  type        = string
  sensitive   = true
  default     = ""
}

variable "redis_connection_cidrs" {
  description = "Trusted CIDR ranges allowed for Redis egress when reusing an existing Redis endpoint."
  type        = list(string)
  default     = []
}

variable "skip_migrations" {
  description = "Skip migrations on Lambda startup (default true). The database must then be migrated out-of-band before serving; the migrate_* outputs carry the inputs for that step (see README, \"Migrations on the serverless root\")."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags for resources."
  type        = map(string)
  default     = {}
}

variable "enable_dashboard" {
  description = "Create the CloudWatch serverless dashboard for the demo Lambda."
  type        = bool
  default     = false
}

variable "enable_xray_tracing" {
  description = "Enable X-Ray active tracing on the Lambda and the matching app-side flag."
  type        = bool
  default     = false
}

variable "enable_lambda_insights" {
  description = "Attach the CloudWatch Lambda Insights policy and dashboard widgets."
  type        = bool
  default     = false
}

variable "licensing_mode" {
  description = "Licensing deployment mode declared to the server as Licensing__Mode. Defaults to Disabled: the 2026.1 contract is no license envelope, no capacity metering, every entitlement active."
  type        = string
  default     = "Disabled"

  validation {
    condition     = contains(["Disabled", "Enabled"], var.licensing_mode)
    error_message = "licensing_mode must be \"Disabled\" or \"Enabled\"."
  }
}

variable "enable_pro_license" {
  description = "Deliver a signed Pro license to the Lambda via Secrets Manager and set Licensing__Mode=Enabled. Off by default; with no envelope the deployment runs with licensing disabled (all entitlements active), not Community."
  type        = bool
  default     = false
}

variable "enable_bedrock_ai" {
  description = "Grant the Lambda bedrock:InvokeModel for the configured Claude model and route the AI studio (WorkflowGeneration) flows to Amazon Bedrock."
  type        = bool
  default     = false
}

variable "pro_license_content" {
  description = "Signed Pro license envelope JSON (relabeled hyphen-free keyId). Required when enable_pro_license is true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "pro_license_key_id" {
  description = "Hyphen-free license keyId as relabeled in the envelope (Licensing__TrustedKeys__<keyId>)."
  type        = string
  default     = "honuademo2026q2"
}

variable "pro_license_trusted_public_key" {
  description = "Ed25519 public key (base64url, with base64url: prefix) that verifies the Pro license signature. Required when enable_pro_license is true."
  type        = string
  default     = ""
}

variable "bedrock_ai_model" {
  description = "Bedrock model id for the AI studio flows. Defaults to the cross-region Claude Sonnet 4.5 inference profile."
  type        = string
  default     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "bedrock_ai_region" {
  description = "AWS region the server invokes Bedrock in. Defaults to us-west-2."
  type        = string
  default     = "us-west-2"
}

variable "enable_control_plane_events" {
  description = "Provision the event-driven control-plane reconcile path (EventBridge Batch-state-change reconcile Lambda + EventBridge Scheduler backstop Lambda, ControlPlane__TriggerMode=Event). Off by default."
  type        = bool
  default     = false
}

variable "control_plane_events_image" {
  description = "Optional dedicated image URI for the control-plane reconcile/backstop Lambdas. Defaults to the API image when empty."
  type        = string
  default     = ""
}

variable "control_plane_events_memory_size" {
  description = "Memory (MB) for the control-plane reconcile/backstop Lambdas."
  type        = number
  default     = 1024
}

variable "control_plane_events_timeout_seconds" {
  description = "Timeout (seconds) for the control-plane reconcile/backstop Lambdas."
  type        = number
  default     = 120
}

variable "control_plane_scheduled_tick_schedules" {
  description = "EventBridge Scheduler cadences for the PERIODIC control-plane ticks (Phase 3): map of tick kind -> rate(...)/cron(...) expression. Only used when enable_control_plane_events is true (TriggerMode=Event). Defaults mirror the in-process timer cadences."
  type        = map(string)
  default = {
    WorkflowSchedule     = "rate(1 minute)"
    JobReconciliation    = "rate(1 minute)"
    TileCacheExpiry      = "rate(5 minutes)"
    TileCacheEviction    = "rate(5 minutes)"
    WorkspaceCleanup     = "rate(1 hour)"
    FileStorageCleanup   = "rate(1 hour)"
    TemporaryFileCleanup = "rate(30 minutes)"
    DigestFlush          = "rate(5 minutes)"
  }
}

variable "bedrock_ai_max_tokens" {
  description = "Max output tokens for Bedrock AI generation (WorkflowGeneration provider MaxTokens)."
  type        = number
  default     = 4096

  validation {
    condition     = var.bedrock_ai_max_tokens >= 256 && var.bedrock_ai_max_tokens <= 32768
    error_message = "bedrock_ai_max_tokens must be between 256 and 32768 (server-side WorkflowGeneration validation range)."
  }
}

variable "bedrock_ai_timeout_seconds" {
  description = "Per-request timeout for Bedrock AI generation (WorkflowGeneration provider TimeoutSeconds)."
  type        = number
  default     = 120

  validation {
    condition     = var.bedrock_ai_timeout_seconds >= 5 && var.bedrock_ai_timeout_seconds <= 300
    error_message = "bedrock_ai_timeout_seconds must be between 5 and 300 (server-side WorkflowGeneration validation range)."
  }
}

variable "permissions_boundary_arn" {
  description = "Operator-owned boundary for every workload role in a certification cell."
  type        = string
  default     = null
}

variable "use_batch_service_linked_role" {
  description = "Use the operator-precreated AWS Batch service-linked role for bounded certification cells."
  type        = bool
  default     = false
}

variable "cors_allowed_origins" {
  description = "Browser origins allowed to call the API (for example the Honua Console/Studio origin), rendered as Cors__AllowedOrigins__<n> and as API Gateway CORS. Empty (default) configures no CORS; API-only cells need none."
  type        = list(string)
  default     = []
  nullable    = false
}

# --- GP on AWS Batch (Fargate Spot) -----------------------------------------
# The Lambda+Batch GA cell: the Lambda serves the API and geoprocessing/import
# jobs run on a scale-to-zero Fargate Spot Batch queue. Off by default.

variable "enable_gp_batch" {
  description = "Provision the AWS Batch (Fargate Spot) backend for geoprocessing/import jobs and wire it into the server's ControlPlane execution-workload catalog (the Lambda+Batch cell). Off by default."
  type        = bool
  default     = false
}

variable "gp_batch_image" {
  description = "Digest-pinned image (registry/repository@sha256:<64 hex>) for the GP Batch job. Use the generic (ECS) server image: the job definitions set no command or entryPoint, so the container runs the image's own entrypoint, and the Lambda AOT image's entrypoint is built for the Lambda runtime. Empty falls back to honua_image_uri, which is only correct for an image that serves both roles."
  type        = string
  default     = ""
}

variable "gp_batch_cpu_architecture" {
  description = "Fargate CPU architecture for the GP job (X86_64 or ARM64). Must match gp_batch_image. Defaults to X86_64, the architecture the 2026.1 platform manifest pins for the generic ECS image (awsEcsArchitecture: x86_64)."
  type        = string
  default     = "X86_64"
}

variable "gp_batch_max_vcpus" {
  description = "Maximum aggregate vCPUs the GP Fargate Spot compute environment may scale to. Caps concurrent jobs and cost; scales to zero between jobs."
  type        = number
  default     = 16
}

variable "gp_batch_data_bucket_arn" {
  description = "Optional S3 bucket ARN the GP job role may read and write. Only used when gp_batch_data_bucket_enabled is true."
  type        = string
  default     = ""
}

variable "gp_batch_data_bucket_enabled" {
  description = "Grant the GP job role S3 access to gp_batch_data_bucket_arn. A separate plan-time-known flag because the ARN may be unknown until apply; set both together."
  type        = bool
  default     = false
}
