variable "name_prefix" {
  description = "Name prefix for resources."
  type        = string
  default     = "honua"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "tags" {
  description = "Additional tags to apply to resources."
  type        = map(string)
  default     = {}
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets."
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "existing_vpc_id" {
  description = "Existing VPC ID to reuse instead of creating a new VPC."
  type        = string
  default     = ""
}

variable "existing_vpc_cidr" {
  description = "CIDR block for existing_vpc_id. Required when reusing a VPC."
  type        = string
  default     = ""
}

variable "existing_public_subnet_ids" {
  description = "Public subnet IDs in existing_vpc_id. Required when reusing a VPC."
  type        = list(string)
  default     = []
}

variable "existing_private_subnet_ids" {
  description = "Private subnet IDs in existing_vpc_id. Required when reusing a VPC."
  type        = list(string)
  default     = []
}

variable "enable_nat_gateway" {
  description = "Whether to provision NAT gateways for private subnets."
  type        = bool
  default     = true
}

variable "image" {
  description = "Lambda container image URI (ECR). Prefer Honua Lambda AOT tags (`vX.Y.Z-lambda-aot`); JIT tags (`vX.Y.Z-lambda`) are debug fallback."
  type        = string
}

variable "lambda_memory_size" {
  description = "Lambda memory size in MB."
  type        = number
  default     = 1024
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout in seconds. API Gateway HTTP API has a 30-second integration timeout ceiling."
  type        = number
  default     = 30
  validation {
    condition     = var.lambda_timeout_seconds >= 10 && var.lambda_timeout_seconds <= 900
    error_message = "Lambda timeout must be between 10 and 900 seconds."
  }
}

variable "lambda_ephemeral_storage_mb" {
  description = "Lambda ephemeral storage size in MB."
  type        = number
  default     = 512
}

variable "lambda_architectures" {
  description = "Lambda architectures (x86_64 or arm64)."
  type        = list(string)
  default     = ["arm64"]
}

variable "lambda_reserved_concurrent_executions" {
  description = "Reserved concurrency limit for the Lambda function (null for unreserved)."
  type        = number
  default     = null
}

variable "lambda_alias_name" {
  description = "Stable Lambda alias used for API Gateway traffic and control-plane rollouts."
  type        = string
  default     = "live"
}

variable "lambda_alias_version" {
  description = "Published Lambda version to pin the stable alias to. Leave null to follow the current published version from this apply."
  type        = string
  default     = null

  validation {
    condition     = var.lambda_alias_version == null || (trimspace(var.lambda_alias_version) != "" && trimspace(var.lambda_alias_version) != "$LATEST")
    error_message = "lambda_alias_version must be null or a published Lambda version number, never an empty string or $LATEST."
  }
}

variable "admin_password" {
  description = "Admin API password for Honua (required in non-dev)."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.admin_password) >= 32
    error_message = "admin_password must be at least 32 characters (it is also used as Security__ConnectionEncryption__MasterKey)."
  }
}

variable "skip_migrations" {
  description = "Skip database migrations on startup."
  type        = bool
  default     = true
}

variable "db_username" {
  description = "PostgreSQL admin username."
  type        = string
  default     = "honua"
}

variable "db_password" {
  description = "PostgreSQL admin password. Leave null to auto-generate."
  type        = string
  sensitive   = true
  default     = null
}

variable "db_name" {
  description = "PostgreSQL database name."
  type        = string
  default     = "honua"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "RDS allocated storage in GB."
  type        = number
  default     = 20
}

variable "db_publicly_accessible" {
  description = "Whether the RDS instance is publicly accessible."
  type        = bool
  default     = false
}

variable "db_additional_ingress_cidrs" {
  description = "Additional CIDRs allowed to access PostgreSQL (for controlled migration/PostGIS operations)."
  type        = list(string)
  default     = []
}

variable "db_multi_az" {
  description = "Enable Multi-AZ for RDS."
  type        = bool
  default     = false
}

variable "db_require_ssl" {
  description = "Append SSL requirements to the connection string."
  type        = bool
  default     = true
}

variable "existing_db_endpoint" {
  description = "Existing PostgreSQL endpoint to reuse. Set with existing_db_connection_string."
  type        = string
  default     = ""
}

variable "existing_db_connection_string" {
  description = "Existing PostgreSQL connection string to reuse. Set with existing_db_endpoint."
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_postgis" {
  description = "Attempt to enable PostGIS and PostGIS Raster via local-exec (requires psql + network access)."
  type        = bool
  default     = false
}

variable "postgis_readiness_max_attempts" {
  description = "Maximum readiness attempts before PostGIS enablement fails."
  type        = number
  default     = 90

  validation {
    condition     = var.postgis_readiness_max_attempts >= 1
    error_message = "postgis_readiness_max_attempts must be at least 1."
  }
}

variable "postgis_readiness_sleep_seconds" {
  description = "Seconds to sleep between PostgreSQL readiness attempts."
  type        = number
  default     = 10

  validation {
    condition     = var.postgis_readiness_sleep_seconds >= 1
    error_message = "postgis_readiness_sleep_seconds must be at least 1."
  }
}

variable "additional_env" {
  description = "Additional environment variables for the Lambda function."
  type        = map(string)
  default     = {}
}

variable "redis_connection_string" {
  description = "Redis connection string for multi-node mode. Leave empty to create Redis."
  type        = string
  default     = ""
  sensitive   = true
}

variable "redis_connection_cidrs" {
  description = "Trusted CIDR ranges allowed for Redis egress when reusing an existing Redis endpoint."
  type        = list(string)
  default     = []
}

variable "redis_auth_token" {
  description = "Redis auth token (used when creating Redis). Leave empty to auto-generate."
  type        = string
  default     = ""
  sensitive   = true
}

variable "redis_enabled" {
  description = "Provision Redis (ElastiCache) for multi-node mode."
  type        = bool
  default     = true
}

variable "redis_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_engine_version" {
  description = "Redis engine version."
  type        = string
  default     = "7.0"
}

variable "redis_parameter_group_name" {
  description = "Redis parameter group name."
  type        = string
  default     = "default.redis7"
}

variable "redis_num_cache_clusters" {
  description = "Number of cache clusters in the replication group. Use 1 for lowest-cost validation; use >=2 for HA failover."
  type        = number
  default     = 1
}

variable "redis_port" {
  description = "Redis port."
  type        = number
  default     = 6379
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days."
  type        = number
  default     = 365
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway instead of one per AZ (cost savings for non-prod)."
  type        = bool
  default     = true
}

variable "api_throttle_burst_limit" {
  description = "API Gateway burst throttle limit (requests)."
  type        = number
  default     = 100
}

variable "api_throttle_rate_limit" {
  description = "API Gateway steady-state throttle limit (requests per second)."
  type        = number
  default     = 50
}

variable "cors_allowed_origins" {
  description = "List of allowed CORS origins. Set to null to disable CORS."
  type        = list(string)
  default     = null
}

variable "db_engine_version" {
  description = "PostgreSQL engine version for RDS."
  type        = string
  default     = "15"
}

variable "serve_admin_ui" {
  description = "Whether to serve the Honua admin UI."
  type        = bool
  default     = false
}

variable "db_connection_string_options" {
  description = "Extra Npgsql options appended to the generated connection string, e.g. \"Maximum Pool Size=4;Connection Idle Lifetime=60\". A leading separator is added automatically. With many concurrent Lambda environments, keep Maximum Pool Size small — each environment gets its own pool."
  type        = string
  default     = ""

  validation {
    condition     = !startswith(var.db_connection_string_options, ";")
    error_message = "db_connection_string_options must not start with ';' — the separator is added automatically."
  }
}

variable "db_apply_immediately" {
  description = "Apply RDS instance modifications (e.g. instance class changes) immediately instead of waiting for the maintenance window. Causes a short outage on resize; acceptable for non-prod stacks."
  type        = bool
  default     = false
}

# --- Serverless observability ---------------------------------------------
# CloudWatch dashboard + X-Ray active tracing for the demo Lambda. All default
# off so existing stacks are unchanged until an operator opts in.

variable "enable_dashboard" {
  description = "Create a CloudWatch dashboard for the Honua Lambda (duration/errors/throttles/concurrency + cold-start + custom Honua metrics). Default off."
  type        = bool
  default     = false
}

variable "enable_xray_tracing" {
  description = "Enable AWS X-Ray active tracing on the Lambda function and grant the least-privilege xray:PutTraceSegments / GetSamplingRules permissions. Pairs with the app-side Tracing__XRay__Enabled flag. Default off."
  type        = bool
  default     = false
}

variable "enable_lambda_insights" {
  description = "Attach the CloudWatch Lambda Insights managed policy and surface the LambdaInsights namespace widgets on the dashboard. The Lambda Insights extension layer must be present in the container image/layer for metrics to flow. Default off."
  type        = bool
  default     = false
}

variable "honua_metrics_namespace" {
  description = "CloudWatch namespace that the Honua custom metrics (cold-start, custom Honua meters) are published to via an ADOT/EMF collector. Used by the dashboard's custom-metric widgets. Empty disables those widgets."
  type        = string
  default     = "Honua/Serverless"
}

# --- GP on AWS Batch (Fargate Spot) ---------------------------------------
# Optional, off by default. When enabled, provisions a Fargate Spot Batch
# compute environment + queue + job definition for Honua geoprocessing/import
# jobs, grants the Lambda execution role scoped batch:SubmitJob/DescribeJobs/
# TerminateJob, and surfaces the queue/job-definition ARNs to the server as a
# ControlPlane:ExecutionWorkloads entry (Backend=honua-aws-batch).

variable "enable_gp_batch" {
  description = "Provision the AWS Batch (Fargate Spot) backend for Honua geoprocessing/import jobs and wire it into the server's ControlPlane execution-workload catalog. Off by default so existing deploys are unchanged."
  type        = bool
  default     = false
}

variable "gp_batch_image" {
  description = "Container image URI (ECR) for the geoprocessing Batch job. Defaults to the same image as the Lambda when empty."
  type        = string
  default     = ""
}

variable "gp_batch_workload_id" {
  description = "Stable WorkloadId the server's ControlPlane uses to select this Batch workload (ControlPlane:ExecutionWorkloads)."
  type        = string
  default     = "geoprocessing-batch"
}

variable "gp_batch_workload_name" {
  description = "Human-friendly workload name surfaced on the execution-workload catalog entry."
  type        = string
  default     = "Honua Geoprocessing (AWS Batch)"
}

variable "gp_batch_cpu_architecture" {
  description = "CPU architecture for the Fargate GP task (X86_64 or ARM64). ARM64 (Graviton) Fargate Spot is cheaper; match the image build."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.gp_batch_cpu_architecture)
    error_message = "gp_batch_cpu_architecture must be X86_64 or ARM64."
  }
}

variable "gp_batch_max_vcpus" {
  description = "Maximum aggregate vCPUs the GP Fargate Spot compute environment may scale to. Caps concurrent job throughput (and cost). Scales to zero between jobs."
  type        = number
  default     = 16
}

variable "gp_batch_data_bucket_arn" {
  description = "Optional S3 bucket ARN the GP job role may read/write (e.g. the FileStorage data bucket). Leave empty to skip granting S3 access."
  type        = string
  default     = ""
}

# --- GP job-definition POOL (size tiers) --------------------------------------
# Terraform provisions a DURABLE per-environment substrate, NOT a unique per-job
# config. Per-job sizing happens at RUNTIME: the server's AwsBatchComputeBackend
# overrides vCPU / memory / timeout / retry per job at SubmitJob time
# (ContainerOverrides + RetryStrategy + Timeout) with zero infra change, so
# terraform must NOT template those per job.
#
# The ONLY job-def knob SubmitJob cannot override is ephemeral (scratch) storage.
# So the module mints a fixed POOL of 4 job definitions (gp-s/m/l/xl, see
# local.gp_batch_tiers in batch.tf) differing ONLY by ephemeral storage
# (20/50/100/200 GiB); the server selects the tier per job. vCPU/memory are just
# job-def DEFAULTS (1 vCPU / 2048 MiB) the server overrides. There are
# intentionally NO per-job vcpus/memory/timeout/retry/ephemeral/gpu variables.

# --- GPU (substrate flag, out of scope) ---------------------------------------
# GPU is NOT supported on the Fargate-Spot path (GPU requires an EC2 / managed-EC2
# compute environment with a GPU instance type and an ECS-GPU AMI). Enabling it
# is a separate, opt-in GPU compute environment, out of scope for this substrate.
# This flag exists only to make that decision explicit; it provisions NOTHING
# today (no EC2/GPU resources). Leave false on the default Fargate-Spot path.
variable "gp_gpu_enabled" {
  description = "Out-of-scope placeholder for a future opt-in GPU compute environment. GPU is NOT supported on Fargate-Spot and this flag provisions no EC2/GPU resources today; leave false."
  type        = bool
  default     = false

  validation {
    condition     = var.gp_gpu_enabled == false
    error_message = "gp_gpu_enabled is a placeholder only — GPU compute environments are out of scope and not yet implemented. Leave it false."
  }
}

# --- Dedicated GP worker (GDAL) ECR repository --------------------------------
# Today GP reuses the Honua Lambda image and branches to the worker via
# HONUA_JOB_KIND. This optional repo gives the GP/GDAL worker its own image
# lifecycle (independent of the Lambda image cadence). Off by default so
# existing deploys are unchanged; the repo name is the same with or without the
# flag, so an operator can pre-create it, push, then enable.

variable "create_worker_gdal_repo" {
  description = "Create a dedicated worker-gdal ECR repository for the GP/GDAL worker image (separate from the Honua Lambda image). Off by default; GP defaults to reusing the Lambda image via HONUA_JOB_KIND."
  type        = bool
  default     = false
}

variable "worker_gdal_repo_image_tag_mutability" {
  description = "Image tag mutability for the worker-gdal ECR repository (MUTABLE or IMMUTABLE). IMMUTABLE is recommended so a pushed cert/job tag can never be silently overwritten."
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.worker_gdal_repo_image_tag_mutability)
    error_message = "worker_gdal_repo_image_tag_mutability must be MUTABLE or IMMUTABLE."
  }
}

variable "worker_gdal_repo_max_image_count" {
  description = "Number of most-recent images the worker-gdal ECR lifecycle policy retains (older untagged/extra images are expired to control storage cost)."
  type        = number
  default     = 10

  validation {
    condition     = var.worker_gdal_repo_max_image_count >= 1
    error_message = "worker_gdal_repo_max_image_count must be at least 1."
  }
}

variable "worker_gdal_repo_force_delete" {
  description = "Allow terraform destroy to delete the worker-gdal ECR repository even when it still contains images. Convenient for ephemeral cert environments; leave false for anything durable."
  type        = bool
  default     = false
}

# --- Pro license (Secrets Manager delivery) -------------------------------
# Optional, off by default. When enabled, stores the signed Pro license
# envelope in a Secrets Manager secret, grants the Lambda role
# secretsmanager:GetSecretValue on it, and injects
# Licensing__LicenseContentSecretRef + Licensing__TrustedKeys__<keyId> so the
# server activates Pro (editing/sync/streaming/geocoding) without the ~2KB
# envelope having to fit Lambda's 4KB environment-variable limit. The server
# resolves the reference at startup and falls back to Community if unreachable.

variable "enable_pro_license" {
  description = "Deliver a signed Pro license to the Lambda via Secrets Manager. Off by default; when off the server runs Community. Requires pro_license_content and pro_license_trusted_public_key when enabled."
  type        = bool
  default     = false
}

# --- AI studio on Amazon Bedrock ------------------------------------------
# Optional, off by default. When enabled, grants the Lambda execution role
# least-privilege bedrock:InvokeModel / InvokeModelWithResponseStream on the
# Claude model the server's WorkflowGeneration uses, and injects the
# WorkflowGeneration__* env so the AI studio flows route to Bedrock. The server
# calls Bedrock via the Lambda execution role (AWS credential chain) — without
# this grant the AI console gets AccessDenied.

variable "enable_bedrock_ai" {
  description = "Grant the Lambda execution role bedrock:InvokeModel / InvokeModelWithResponseStream for the configured Claude model and route the server's AI studio (WorkflowGeneration) flows to Amazon Bedrock. Off by default so existing deploys are unchanged."
  type        = bool
  default     = false
}

variable "pro_license_content" {
  description = "The signed Pro license envelope JSON (the relabeled, hyphen-free keyId envelope, e.g. keyId=honuademo2026q2). Stored in a dedicated Secrets Manager secret and referenced by Licensing__LicenseContentSecretRef. Required when enable_pro_license is true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "pro_license_key_id" {
  description = "The license signing keyId as relabeled in the envelope. Must be hyphen-free so it is a legal Lambda env var name segment (Licensing__TrustedKeys__<keyId>). Defaults to the demo key."
  type        = string
  default     = "honuademo2026q2"

  validation {
    condition     = can(regex("^[A-Za-z_][A-Za-z0-9_]*$", var.pro_license_key_id))
    error_message = "pro_license_key_id must be a valid environment-variable name segment (letters, digits, underscore; no hyphens)."
  }
}

variable "pro_license_trusted_public_key" {
  description = "The Ed25519 public key (base64url, with the base64url: prefix) that verifies the Pro license signature. Injected as Licensing__TrustedKeys__<pro_license_key_id>. Required when enable_pro_license is true."
  type        = string
  default     = ""
}

variable "bedrock_ai_model" {
  description = "Bedrock model id the server's WorkflowGeneration uses. Defaults to the cross-region Claude Sonnet 4.5 inference profile (the `us.` prefix routes across us-east-1/us-east-2/us-west-2). The IAM grant is scoped to this model's inference-profile + foundation-model ARNs."
  type        = string
  default     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "bedrock_ai_region" {
  description = "AWS region the server invokes Bedrock in (WorkflowGeneration provider Region). Defaults to us-west-2."
  type        = string
  default     = "us-west-2"
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

# --- Control-plane event triggers (TriggerMode=Event) ---------------------
# Optional, off by default. When enabled, provisions a reconcile Lambda fired by
# EventBridge on Batch job state changes plus a backstop Lambda fired every ~2
# minutes by EventBridge Scheduler, so the control plane reconciles event-driven
# (no always-on in-process timer). Both Lambdas reuse the server image and the
# API host's DI env, and add ControlPlane__TriggerMode=Event.

variable "enable_control_plane_events" {
  description = "Provision the event-driven control-plane reconcile path: a reconcile Lambda fired by EventBridge on Batch job state changes and a backstop Lambda fired every ~2 minutes by EventBridge Scheduler, with ControlPlane__TriggerMode=Event. Off by default so existing deploys are unchanged."
  type        = bool
  default     = false
}

variable "control_plane_events_image" {
  description = "Container image URI (ECR) for the control-plane reconcile/backstop Lambdas. Defaults to the same image as the API Lambda (var.image) when empty; both event handlers are selected at runtime via HONUA_CONTROL_PLANE_LAMBDA_HANDLER, so the image must bundle the batch-event and backstop entrypoints."
  type        = string
  default     = ""
}

variable "control_plane_events_memory_size" {
  description = "Memory (MB) for the control-plane reconcile/backstop Lambdas."
  type        = number
  default     = 1024
}

variable "control_plane_events_timeout_seconds" {
  description = "Timeout (seconds) for the control-plane reconcile/backstop Lambdas. Not bound by the API Gateway 30s ceiling since these are invoked asynchronously by EventBridge / EventBridge Scheduler."
  type        = number
  default     = 120

  validation {
    condition     = var.control_plane_events_timeout_seconds >= 10 && var.control_plane_events_timeout_seconds <= 900
    error_message = "control_plane_events_timeout_seconds must be between 10 and 900 seconds."
  }
}

variable "control_plane_events_reserved_concurrent_executions" {
  description = "Reserved concurrency for the control-plane reconcile/backstop Lambdas (null for unreserved)."
  type        = number
  default     = null
}

variable "control_plane_scheduled_tick_schedules" {
  description = <<-EOT
    EventBridge Scheduler cadences for the PERIODIC (bucket-b) control-plane ticks (Phase 3). Each
    entry maps a tick KIND (matching Honua's ScheduledTickKind enum) to a schedule_expression
    (rate(...) or cron(...)). Under ControlPlane__TriggerMode=Event these schedules drive the
    server's idempotent per-tick bodies through the scheduled-tick Lambda/endpoint instead of an
    always-on in-process timer; under Poll the server hosts the timers and these are inert (the whole
    block is gated on enable_control_plane_events). Defaults mirror the in-process timer cadences:
    WorkflowSchedule ~1min, JobReconciliation ~1min, TileCacheExpiry/Eviction a few minutes, the
    cleanups hourly/30-min, DigestFlush a few minutes. Override per environment as needed.
  EOT
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
