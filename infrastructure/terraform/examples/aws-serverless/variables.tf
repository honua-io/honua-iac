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

variable "lambda_architectures" {
  description = "Lambda architectures for validation. arm64 is the default."
  type        = list(string)
  default     = ["arm64"]
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
  description = "Skip migrations on Lambda startup."
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

variable "enable_pro_license" {
  description = "Deliver a signed Pro license to the Lambda via Secrets Manager so editing/sync/streaming/geocoding work. Off by default (Community)."
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
