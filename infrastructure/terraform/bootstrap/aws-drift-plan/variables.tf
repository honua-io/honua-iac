variable "region" {
  description = "Region the IAM resources are managed from (IAM itself is global)."
  type        = string
  default     = "us-east-1"
}

variable "oidc_provider_arn" {
  description = "ARN of the existing token.actions.githubusercontent.com OIDC provider (the account already has one; this root never creates it)."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must be the GitHub Actions OIDC provider of this account."
  }
}

variable "state_bucket_name" {
  description = "The account's Terraform state bucket (bootstrap/aws-tfstate). The roles read state under their key prefix and write only lock files there."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be an S3 bucket name."
  }
}

variable "max_session_duration_seconds" {
  description = "Maximum session for both roles. A drift plan finishes well inside an hour."
  type        = number
  default     = 3600
}

# --- honua-demo-infra (demo.honua.io) --------------------------------------

variable "demo_infra_oidc_subjects" {
  description = <<-EOT
    Exact subjects allowed to assume the demo plan-only role. Default: the nightly
    drift job, which runs in the demo-drift environment. Give that environment a
    deployment-branch policy of trunk only, so the role is reachable only from
    trunk AND that environment (GitHub puts one of the two in `sub`, never both).
  EOT
  type        = list(string)
  default     = ["repo:honua-io/honua-demo-infra:environment:demo-drift"]
  validation {
    condition = length(var.demo_infra_oidc_subjects) > 0 && alltrue([
      for subject in var.demo_infra_oidc_subjects : can(regex("^repo:honua-io/honua-demo-infra:environment:[A-Za-z0-9_.-]+$", subject))
    ])
    error_message = "Only exact honua-io/honua-demo-infra environment subjects may assume the demo drift role (no wildcards, no branch or pull_request subjects)."
  }
}

variable "demo_state_key_prefix" {
  description = "State keys of the honua-demo-infra stacks."
  type        = string
  default     = "demo/aws-demo/"
}

variable "demo_region" {
  description = "Region of the demo.honua.io resources."
  type        = string
  default     = "us-west-2"
}

variable "demo_secret_name_prefixes" {
  description = "Name prefixes of the Terraform-managed demo secrets. Refresh reads their values (aws_secretsmanager_secret_version), so the role may GetSecretValue on exactly these: the module's secrets and the STAC seed receipt secret."
  type        = list(string)
  default     = ["honua-demo-demo/", "honua-demo/demo/"]
}

variable "demo_denied_secret_names" {
  description = "Demo secrets the role may never read, even under demo_secret_name_prefix: operator-owned material that Terraform only references by ARN."
  type        = list(string)
  default     = ["honua-demo-demo/operation-key-ring"]
}

variable "demo_readable_object_arns" {
  description = "S3 object ARNs the demo stacks manage as aws_s3_object (refresh issues HeadObject). Empty derives the published-manifest prefix of honua-demo-data-<account>."
  type        = list(string)
  default     = []
}

# --- honua-iac bootstrap roots ---------------------------------------------

variable "iac_bootstrap_oidc_subjects" {
  description = "Exact subjects allowed to assume the bootstrap plan-only role: the honua-iac bootstrap-drift environment (trunk-only deployment-branch policy)."
  type        = list(string)
  default     = ["repo:honua-io/honua-iac:environment:bootstrap-drift"]
  validation {
    condition = length(var.iac_bootstrap_oidc_subjects) > 0 && alltrue([
      for subject in var.iac_bootstrap_oidc_subjects : can(regex("^repo:honua-io/honua-iac:environment:[A-Za-z0-9_.-]+$", subject))
    ])
    error_message = "Only exact honua-io/honua-iac environment subjects may assume the bootstrap drift role."
  }
}

variable "bootstrap_state_key_prefix" {
  description = "State keys of the honua-iac bootstrap roots."
  type        = string
  default     = "bootstrap/"
}
