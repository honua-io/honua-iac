###############################################################################
# Inputs for the real-AWS certification tier (examples/aws-cert, honua-iac#2164).
###############################################################################

variable "region" {
  description = "AWS region for the certification stack."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix used for resource names. Combined with environment yields the honua-cert-* surface."
  type        = string
  default     = "honua-cert"
}

variable "environment" {
  description = "Environment name. 'cert' yields honua-cert-cert-* ARNs."
  type        = string
  default     = "cert"
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}

variable "honua_image" {
  description = "Lambda container image URI (ECR). Use a *-lambda-aot tag pinned to an immutable release tag or digest."
  type        = string
}

variable "honua_admin_password" {
  description = "Admin API password for Honua (minimum 32 characters; also used as Security__ConnectionEncryption__MasterKey)."
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "PostgreSQL admin password. Leave null to auto-generate."
  type        = string
  sensitive   = true
  default     = null
}

# --- GP per-job Batch ------------------------------------------------------

variable "gp_batch_image" {
  description = "ECR image URI for the GP/GDAL worker. Defaults to honua_image (HONUA_JOB_KIND branch) when empty. The cert workflow can re-apply with a per-job image to mint a job definition sized to a specific GP job."
  type        = string
  default     = ""
}

variable "gp_batch_cpu_architecture" {
  description = "CPU architecture for the cert GP Fargate task (X86_64 or ARM64). Must match the GP image build."
  type        = string
  default     = "X86_64"
}

# Per-job sizing knobs forwarded to the module so the honua-devops gp runtime
# adapter can re-apply with a profile sized to a specific GP job. The adapter
# sets these via TF_VAR_gp_batch_*; the defaults mirror the module so the cert
# stack applies cleanly when a knob is not specified. (vCPU/memory/timeout/retry
# are also SubmitJob overrides at run time; image/arch/ephemeral/GPU are not, so
# they must be templated into the job definition here.)
variable "gp_batch_workload_id" {
  description = "Stable workload identifier for the per-job GP Batch resources."
  type        = string
  default     = "geoprocessing-batch"
}

variable "gp_batch_workload_name" {
  description = "Human-readable name for the per-job GP Batch workload."
  type        = string
  default     = "Honua Geoprocessing (AWS Batch)"
}

variable "gp_batch_vcpus" {
  description = "Default vCPUs for the GP job definition (SubmitJob can override per job)."
  type        = number
  default     = 1
}

variable "gp_batch_memory_mib" {
  description = "Default memory (MiB) for the GP job definition (SubmitJob can override per job)."
  type        = number
  default     = 2048
}

variable "gp_batch_max_vcpus" {
  description = "Max vCPUs ceiling for the GP Fargate-Spot compute environment."
  type        = number
  default     = 16
}

variable "gp_batch_timeout_seconds" {
  description = "Default job timeout (seconds) for the GP job definition."
  type        = number
  default     = 3600
}

variable "gp_batch_retry_attempts" {
  description = "Default retry attempts for the GP job definition."
  type        = number
  default     = 1
}

variable "gp_batch_ephemeral_storage_gib" {
  description = "Ephemeral scratch storage (GiB) for the GP Fargate task; templated into the job definition because SubmitJob cannot override it. null leaves the Fargate 20 GiB default; otherwise 21-200."
  type        = number
  default     = null
}

variable "gp_batch_gpu_count" {
  description = "Default GPU count for the GP job definition. NOT supported on Fargate-Spot (GPU requires an EC2 compute environment); leave 0 on the default path."
  type        = number
  default     = 0
}

variable "create_worker_gdal_repo" {
  description = "Create the dedicated worker-gdal ECR repository for the cert GP worker image."
  type        = bool
  default     = true
}

# --- Certification budget guardrail ----------------------------------------

variable "monthly_budget_usd" {
  description = "Monthly cost ceiling (USD) for the certification account/stack. An SNS-backed budget alarm fires as spend approaches this."
  type        = number
  default     = 200

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than 0."
  }
}

variable "budget_alert_emails" {
  description = "Email addresses subscribed to the budget SNS topic. Each receives a confirmation email it must accept before alerts deliver."
  type        = list(string)
  default     = []
}

variable "budget_alert_thresholds_percent" {
  description = "Percent-of-budget thresholds that trigger a notification (actual + forecasted)."
  type        = list(number)
  default     = [50, 80, 100]
}

# --- GitHub OIDC trust scoping (passed to the aws-github-oidc component) ----

variable "github_owner" {
  description = "GitHub org/owner allowed to assume the cert OIDC role."
  type        = string
  default     = "honua-io"
}

variable "github_repository" {
  description = "GitHub repository whose cert workflow may assume the role."
  type        = string
  default     = "honua-server"
}

variable "github_oidc_subjects" {
  description = "Explicit OIDC `sub` patterns allowed to assume the cert role. Overrides github_owner/github_repository when non-empty. Pin to a GitHub Environment for the tightest scope, e.g. [\"repo:honua-io/honua-server:environment:cert\"]."
  type        = list(string)
  default     = []
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false (and pass existing_oidc_provider_arn) if the account already has one."
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "Existing GitHub OIDC provider ARN to reuse when create_oidc_provider = false."
  type        = string
  default     = ""
}
