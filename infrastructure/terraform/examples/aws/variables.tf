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
  default     = "honuaecs"
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
  description = "Admin password for Honua."
  type        = string
  sensitive   = true
}

variable "honua_connection_encryption_master_key" {
  description = "Required connection-key decision. Set null only for a new deployment; existing deployments must set their current key before upgrading."
  type        = string
  sensitive   = true
  nullable    = true
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

variable "honua_image" {
  description = "Container image to deploy to ECS. Pin to a SHA-256 digest."
  type        = string
}

variable "operator_contract_identity" {
  description = "Optional immutable identity inputs for the honua.operator-contract/v1 output. Omit only for disposable, unqualified development plans; certified consumers must provide every required digest and backend/state lineage input."
  type = object({
    candidate_digest      = string
    manifest_digest       = optional(string)
    iac_revision          = string
    terraform_version     = string
    provider_lock_digest  = string
    image_digest          = string
    image_reference       = optional(string)
    backend_config_digest = optional(string)
    state_lineage         = optional(string)
    state_serial          = optional(number)
    workload_identity     = optional(string)
    artifacts = optional(list(object({
      name    = string
      kind    = string
      version = string
      digest  = string
    })), [])
  })
  default = null

  validation {
    condition = var.operator_contract_identity == null || (
      can(regex("^[0-9a-f]{64}$", try(var.operator_contract_identity.candidate_digest, ""))) &&
      can(regex("^([0-9a-f]{40}|[0-9a-f]{64})$", try(var.operator_contract_identity.iac_revision, ""))) &&
      try(trimspace(var.operator_contract_identity.terraform_version) != "", false) &&
      can(regex("^[0-9a-f]{64}$", try(var.operator_contract_identity.provider_lock_digest, ""))) &&
      can(regex("^sha256:[0-9a-f]{64}$", try(var.operator_contract_identity.image_digest, ""))) &&
      (try(var.operator_contract_identity.manifest_digest, null) == null || can(regex("^[0-9a-f]{64}$", var.operator_contract_identity.manifest_digest))) &&
      (try(var.operator_contract_identity.backend_config_digest, null) == null || can(regex("^[0-9a-f]{64}$", var.operator_contract_identity.backend_config_digest))) &&
      (try(var.operator_contract_identity.state_lineage, null) == null || can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.operator_contract_identity.state_lineage))) &&
      (try(var.operator_contract_identity.state_serial, null) == null || try(var.operator_contract_identity.state_serial >= 0, false))
    )
    error_message = "operator_contract_identity must use SHA-256 digests, a 40/64-character IaC revision, a sha256 image digest, a UUID state lineage, and a non-negative state serial when supplied."
  }

  # An immutable identity claim may never be backed by a mutable reference.
  # image_reference must be registry/repository@sha256:<64 hex>; a tag-only
  # reference (":latest", ":2026.1.0") is rejected here rather than silently
  # projected into the contract as an immutable pin.
  # HCL evaluates both operands of || and &&, so every branch below is written
  # as a conditional (which does short-circuit) or wrapped in try/can. A null
  # attribute must fail the check, not crash the plan with a function error.
  validation {
    condition = var.operator_contract_identity == null ? true : (
      try(var.operator_contract_identity.image_reference, null) == null ? true :
      can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*(\\.[A-Za-z0-9._-]+)*(:[0-9]+)?(/[A-Za-z0-9._-]+)+@sha256:[0-9a-f]{64}$", var.operator_contract_identity.image_reference))
    )
    error_message = "operator_contract_identity.image_reference must be digest-pinned as registry/repository@sha256:<64 hex>; a mutable tag is not an immutable pin."
  }

  validation {
    condition = var.operator_contract_identity == null ? true : (
      try(var.operator_contract_identity.image_reference, null) == null ? true :
      try(endswith(var.operator_contract_identity.image_reference, "@${var.operator_contract_identity.image_digest}"), false)
    )
    error_message = "operator_contract_identity.image_reference must end with @<image_digest>; the reference and the digest must describe the same image."
  }

  validation {
    condition = var.operator_contract_identity == null ? true : alltrue([
      for artifact in try(var.operator_contract_identity.artifacts, []) :
      try(trimspace(artifact.name) != "", false) &&
      try(contains(["proxy", "cli", "mcp-server", "helm-chart", "package", "other"], artifact.kind), false) &&
      try(trimspace(artifact.version) != "", false) &&
      can(regex("^[0-9a-f]{64}$", artifact.digest))
    ])
    error_message = "Each operator_contract_identity.artifacts entry needs a name, a supported kind (proxy, cli, mcp-server, helm-chart, package, other), a version, and a 64-character SHA-256 digest."
  }
}

# Licensing (operator ruling 2026-09-12; honua-iac #191, honua-server #4721).
# The 2026.1 candidate ships with licensing disabled: no envelope, no metering,
# every entitlement active. Supplying an envelope is the 2026.2 path.
variable "licensing_mode" {
  description = "Licensing deployment mode declared to the server as Licensing__Mode. Defaults to Disabled (the 2026.1 contract). Supplying pro_license_secret_arn implies Enabled."
  type        = string
  default     = "Disabled"

  validation {
    condition     = contains(["Disabled", "Enabled"], var.licensing_mode)
    error_message = "licensing_mode must be \"Disabled\" or \"Enabled\"."
  }
}

variable "licensing_edition" {
  description = "Edition declared as Licensing__Edition when (and only when) pro_license_secret_arn is set. Ignored with no envelope."
  type        = string
  default     = "Pro"
}

variable "pro_license_secret_arn" {
  description = "Optional ARN of an EXISTING Secrets Manager secret holding the signed Pro license envelope JSON. Leave empty for the 2026.1 licensing-disabled contract; the module never creates, reads or deletes this secret."
  type        = string
  default     = ""
}

variable "pro_license_secret_kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for pro_license_secret_arn."
  type        = string
  default     = ""
}

variable "pro_license_key_id" {
  description = "Hyphen-free license signing keyId as relabeled in the envelope (becomes the env segment Licensing__TrustedKeys__<keyId>). Only used when an envelope is supplied."
  type        = string
  default     = "honuademo2026q2"
}

variable "pro_license_trusted_public_key" {
  description = "Ed25519 public key (base64url: prefix) that verifies the license signature. Required when pro_license_secret_arn is set; a public key only verifies and is not secret."
  type        = string
  default     = ""
}

variable "ai_provider_secret_arn" {
  description = "Optional customer-owned Secrets Manager ARN containing HONUA_AI_PROVIDER_API_KEY. The stack references but never creates, reads, or deletes this secret."
  type        = string
  default     = ""
}

variable "ai_provider_secret_kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for ai_provider_secret_arn."
  type        = string
  default     = ""
}

variable "task_cpu_architecture" {
  description = "Fargate CPU architecture. X86_64 is the release-certified default."
  type        = string
  default     = "X86_64"
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
  description = "Enable PostGIS and PostGIS Raster during apply. Requires the Terraform runner to reach the database endpoint."
  type        = bool
  default     = false
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
  description = "Customer-managed KMS key ARN encrypting the operation key-ring certificate secret. Leave empty for the AWS-managed aws/secretsmanager key. Granted to the execution role only when Redis is configured."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.operation_key_ring_certificate_secret_kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.operation_key_ring_certificate_secret_kms_key_arn))
    error_message = "operation_key_ring_certificate_secret_kms_key_arn must be an exact KMS key ARN or empty."
  }
}

variable "operation_key_ring_certificate_secret_arn" {
  description = "ARN of an existing operator-owned Secrets Manager secret containing base64 PKCS#12 or a JSON {pkcs12,password} bundle with a private key. Required for Redis, including an existing Redis connection. Only the ARN enters Terraform; never pass certificate material in additional_env or tfvars. The module grants the execution role read access; supply operation_key_ring_certificate_secret_kms_key_arn for a customer-managed key."
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

variable "desired_count" {
  description = "Minimum number of ECS tasks. Values greater than 1 require the safe MultiNode inputs."
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum ECS auto-scaling capacity. Values greater than 1 require the safe MultiNode inputs."
  type        = number
  default     = 1
}

variable "deployment_mode" {
  description = "Honua deployment mode. Use MultiNode only with Redis and shared S3 file storage."
  type        = string
  default     = "SingleInstance"
}

variable "file_storage_provider" {
  description = "Honua file storage provider (Local or AwsS3)."
  type        = string
  default     = "Local"
}

variable "file_storage_aws_s3_bucket_name" {
  description = "Existing S3 bucket for shared Honua file storage."
  type        = string
  default     = ""
}

variable "file_storage_aws_s3_region" {
  description = "S3 bucket region. Leave empty to use region."
  type        = string
  default     = ""
}

variable "file_storage_aws_s3_key_prefix" {
  description = "Optional key prefix for Honua objects."
  type        = string
  default     = "honua"
}

variable "canary_enabled" {
  description = "Provision the optional ALB canary ECS service."
  type        = bool
  default     = false
}

variable "canary_image" {
  description = "Optional canary image override."
  type        = string
  default     = ""
}

variable "canary_desired_count" {
  description = "Desired number of ECS tasks in the canary service."
  type        = number
  default     = 1
}

variable "canary_weight_percentage" {
  description = "Percentage of default ALB traffic routed to the canary target group."
  type        = number
  default     = 0
}

variable "alb_deletion_protection" {
  description = "Enable ALB deletion protection."
  type        = bool
  default     = true
}

variable "rds_deletion_protection" {
  description = "Enable deletion protection on the managed production RDS instance. Set false in a separate apply before destroy."
  type        = bool
  default     = true
}

variable "alb_access_logs_enabled" {
  description = "Enable ALB access logs."
  type        = bool
  default     = true
}

variable "alb_access_logs_force_destroy" {
  description = "Force destroy ALB access logs bucket when managed by this stack."
  type        = bool
  default     = true
}

variable "alb_certificate_arn" {
  description = "ACM certificate ARN for the ALB HTTPS listener."
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Optional custom API hostname for ACM-managed TLS and Route53 ALB alias DNS."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID that owns domain_name when Terraform should manage certificate validation and ALB alias DNS."
  type        = string
  default     = ""
}

variable "domain_alias_record_enabled" {
  description = "Create a Route53 alias A record from domain_name to the ALB when domain_name and route53_zone_id are set."
  type        = bool
  default     = true
}

variable "subject_alternative_names" {
  description = "Subject alternative names for the ACM certificate."
  type        = list(string)
  default     = []
}

variable "allow_https_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB over HTTPS during validation."
  type        = list(string)
  default     = []
}

variable "allow_http_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB over HTTP. With this and allow_https_ingress_cidrs both empty and no certificate, the ALB admits only in-VPC traffic (a plan-time check warns)."
  type        = list(string)
  default     = []
}

variable "waf_web_acl_arn" {
  description = "Optional WAFv2 Web ACL ARN associated to the ALB."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags for resources."
  type        = map(string)
  default     = {}
}

variable "enable_bedrock_ai" {
  description = "Grant the ECS task role bedrock:InvokeModel / InvokeModelWithResponseStream for the configured Claude model and route the server's AI studio (WorkflowGeneration) flows to Amazon Bedrock. Off by default so existing deploys are unchanged."
  type        = bool
  default     = false
}

variable "bedrock_ai_model" {
  description = "Bedrock model id the server's WorkflowGeneration uses. Defaults to the cross-region Claude Sonnet 4.5 inference profile (the `us.` prefix routes across us-east-1/us-east-2/us-west-2). The IAM grant is scoped to this model's inference-profile + foundation-model ARNs."
  type        = string
  default     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
  validation {
    condition     = can(regex("^(us[.])?anthropic[.]claude-[a-z0-9-]+-v[0-9]+:[0-9]+$", var.bedrock_ai_model))
    error_message = "Pin a versioned Claude foundation model or us. inference profile; wildcards and arbitrary ARN grants are forbidden."
  }
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

variable "permissions_boundary_arn" {
  description = "Operator-owned boundary for every workload role in a certification cell."
  type        = string
  default     = null
}

variable "cors_allowed_origins" {
  description = "Browser origins allowed to call the API (for example the Honua Console/Studio origin), rendered as Cors__AllowedOrigins__<n>. Empty (default) renders nothing; API-only cells need none."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "operations_policy_rules" {
  description = "Ordered first-match-wins operation policy rules passed to the module and rendered as Operations__Policy__Rules__<n>__<Field>. The server runs in Production, where Operations:Policy denies every typed operation (for example service.publish) unless a rule allows it. decision is Allow, RequireApproval, DryRunFirst or Deny; operation_id defaults to \"*\". Empty (default) keeps the fail-closed default."
  type = list(object({
    operation_id  = optional(string, "*")
    role          = optional(string)
    tier          = optional(string)
    decision      = string
    reason        = optional(string)
    approval_lane = optional(string)
  }))
  default  = []
  nullable = false
}
