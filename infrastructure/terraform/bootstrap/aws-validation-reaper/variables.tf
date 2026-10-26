variable "region" {
  description = "Region the IAM resources are managed from (IAM itself is global)."
  type        = string
  default     = "us-east-1"
}

variable "role_name" {
  description = "Name of the validation reaper role."
  type        = string
  default     = "honua-iac-validation-reaper"
}

variable "oidc_provider_arn" {
  description = "ARN of the existing token.actions.githubusercontent.com OIDC provider."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must be the GitHub Actions OIDC provider of this account."
  }
}

variable "oidc_subjects" {
  description = <<-EOT
    Exact GitHub OIDC subjects allowed to assume the role: the scheduled/dispatched
    reaper job's protected environment, and the two terraform-manual-validation
    environments whose always-step reaps its own cell (--this-run).
  EOT
  type        = list(string)
  default = [
    "repo:honua-io/honua-iac:environment:aws-validation-reaper",
    "repo:honua-io/honua-iac:environment:terraform-ephemeral",
    "repo:honua-io/honua-iac:environment:terraform-live-approval",
  ]
  validation {
    condition = length(var.oidc_subjects) > 0 && alltrue([
      for subject in var.oidc_subjects : can(regex("^repo:honua-io/honua-iac:environment:[A-Za-z0-9_.-]+$", subject))
    ])
    error_message = "Only exact honua-io/honua-iac environment subjects may assume the reaper (no wildcards, no branch subjects)."
  }
}

variable "sweep_regions" {
  description = "Regions the reaper may act in (the workflow's HONUA_AWS_SWEEP_REGIONS)."
  type        = list(string)
  default     = ["us-east-1", "us-west-2"]
  validation {
    condition     = length(var.sweep_regions) > 0 && alltrue([for r in var.sweep_regions : can(regex("^[a-z]{2}-[a-z]+-[0-9]$", r))])
    error_message = "sweep_regions must be explicit AWS region names."
  }
}

variable "max_session_duration" {
  description = "Maximum session length; the reaper job requests 7200 seconds."
  type        = number
  default     = 7200
}
