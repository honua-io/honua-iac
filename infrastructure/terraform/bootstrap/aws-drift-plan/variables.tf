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
    Exact subjects allowed to assume the demo plan-only role:
      demo-drift  the nightly drift job. Its deployment-branch policy is trunk only,
                  so this subject means trunk AND that environment (GitHub puts one
                  of the two in `sub`, never both).
      demo-plan   the pull-request plan job of terraform.yml (honua-demo-infra#104).
                  It runs on PR branches, so it is NOT trunk-pinned: any writer who
                  can push a branch can run a read-only plan with this role, which
                  includes reading state and the Terraform-managed demo secrets.
                  Add required reviewers to demo-plan to gate that, or drop the
                  subject to stop PR plans.

    honua-io/honua-demo-infra issues IMMUTABLE subjects
    (`gh api repos/honua-io/honua-demo-infra/actions/oidc/customization/sub`:
    use_immutable_subject = true), so `sub` is
    repo:honua-io@<owner id>/honua-demo-infra@<repo id>:environment:<name>, never
    the name form. The name form never matches and every assume fails
    (drift-plan run 40579808276). Same form as stacks/aws/stac-seed-gate.tf there.
  EOT
  type        = list(string)
  default = [
    "repo:honua-io@217718039/honua-demo-infra@1310514636:environment:demo-drift",
    "repo:honua-io@217718039/honua-demo-infra@1310514636:environment:demo-plan",
  ]
  validation {
    condition = length(var.demo_infra_oidc_subjects) > 0 && alltrue([
      for subject in var.demo_infra_oidc_subjects : can(regex("^repo:honua-io@[0-9]+/honua-demo-infra@[0-9]+:environment:[A-Za-z0-9_.-]+$", subject))
    ])
    error_message = "honua-demo-infra uses immutable OIDC subjects: only exact repo:honua-io@<owner id>/honua-demo-infra@<repo id>:environment:<name> subjects may assume the demo drift role (no name-form, wildcard, branch or pull_request subjects)."
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

variable "demo_function_name_prefix" {
  description = "Name prefix of the demo's Lambda functions. Refresh reads their environment, which Lambda decrypts with kms:Decrypt on the caller's behalf."
  type        = string
  default     = "honua-demo-demo-"
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
  description = "Exact subjects allowed to assume the bootstrap plan-only role: the honua-iac bootstrap-drift environment (trunk-only deployment-branch policy). honua-io/honua-iac issues name-form subjects (use_immutable_subject = false), like the reaper and release-cell roles that already work."
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
