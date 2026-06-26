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

# --- GP Batch substrate ----------------------------------------------------
# Only substrate-level inputs live here. Per-job sizing (vCPU/memory/timeout/
# retry) is a runtime SubmitJob override applied by the server — NOT a terraform
# variable — and ephemeral storage is fixed by the job-def size-tier pool the
# module mints. So there are intentionally no per-job gp_batch_* knobs.

variable "gp_batch_image" {
  description = "ECR image URI for the GP/GDAL worker. Defaults to honua_image (HONUA_JOB_KIND branch) when empty. Substrate-level: every tier in the job-def pool uses this image."
  type        = string
  default     = ""
}

variable "gp_batch_cpu_architecture" {
  description = "CPU architecture for the cert GP Fargate task (X86_64 or ARM64). Must match the GP image build."
  type        = string
  default     = "X86_64"
}

variable "gp_batch_workload_id" {
  description = "Stable workload identifier for the GP Batch substrate (ControlPlane:ExecutionWorkloads selector)."
  type        = string
  default     = "geoprocessing-batch"
}

variable "gp_batch_workload_name" {
  description = "Human-readable name for the GP Batch workload."
  type        = string
  default     = "Honua Geoprocessing (AWS Batch)"
}

variable "gp_batch_max_vcpus" {
  description = "Max vCPUs ceiling for the GP Fargate-Spot compute environment."
  type        = number
  default     = 16
}

variable "create_worker_gdal_repo" {
  description = "Create the dedicated worker-gdal ECR repository for the cert GP worker image."
  type        = bool
  default     = true
}

# --- Custom-code (untrusted) Batch substrate -------------------------------
# A SEPARATE, hardened Batch family for untrusted user code: empty secrets, a
# minimal task role (scoped artifact S3 only, no DB/secrets), a constrained
# egress allowlist. Off by default in cert; the scoped HONUA_JOB_TOKEN is the
# trust boundary. Only substrate-level inputs live here (per-job sizing is a
# runtime SubmitJob override; tiers are fixed by the module's size pool).

variable "enable_customcode_batch" {
  description = "Provision the hardened custom-code (untrusted) Batch substrate in the cert stack. Off by default."
  type        = bool
  default     = false
}

variable "customcode_batch_image" {
  description = "ECR image URI for the PYTHON custom-code worker (customcode.runtime=python). Defaults to the worker-customcode-python repo (when created) else honua_image."
  type        = string
  default     = ""
}

variable "customcode_dotnet_batch_image" {
  description = "ECR image URI for the DOTNET custom-code worker (customcode.runtime=dotnet; honua-server #2196). Defaults to the worker-customcode-dotnet repo (when created) else honua_image."
  type        = string
  default     = ""
}

variable "customcode_batch_cpu_architecture" {
  description = "CPU architecture for the custom-code Fargate task (X86_64 or ARM64). Must match the worker image build."
  type        = string
  default     = "X86_64"
}

variable "customcode_batch_max_vcpus" {
  description = "Max vCPUs ceiling for the custom-code Fargate-Spot compute environment."
  type        = number
  default     = 16
}

variable "create_worker_customcode_repo" {
  description = "Create the dedicated worker-customcode-python ECR repository for the python custom-code worker image."
  type        = bool
  default     = false
}

variable "create_worker_customcode_dotnet_repo" {
  description = "Create the dedicated worker-customcode-dotnet ECR repository for the .NET custom-code worker image (honua-server #2196)."
  type        = bool
  default     = false
}

variable "customcode_egress_https_cidrs" {
  description = "CIDR allowlist for HTTPS egress from untrusted custom-code tasks (PyPI/GitHub/Honua API/artifact S3). Empty defaults to the VPC CIDR only (no open internet)."
  type        = list(string)
  default     = []
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
