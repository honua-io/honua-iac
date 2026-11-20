variable "member_account_id" {
  type        = string
  description = "Target account identifier: member account or existing shared account, delivered through private SSM tfvars."
  validation {
    condition     = can(regex("^[0-9]{12}$", var.member_account_id))
    error_message = "Supply the member account identifier through private tfvars."
  }
}
variable "lane_principal_arns" {
  type        = set(string)
  description = "Exact existing IAM role ARNs allowed to assume the gate lane role, from private SSM tfvars."
  validation {
    condition     = length(var.lane_principal_arns) > 0 && alltrue([for arn in var.lane_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9_+=,.@/-]+$", arn)) && !strcontains(arn, "*")])
    error_message = "Trust at least one exact IAM role ARN; account roots and wildcards are forbidden."
  }
}

variable "shared_account" {
  type        = bool
  default     = false
  description = "Use shared-account protections and an alert-only tagged-cost budget; skip the organization bootstrap."
}
variable "protected_state_buckets" {
  type        = set(string)
  default     = []
  sensitive   = true
  description = "All existing Terraform state bucket names, supplied privately."
  validation {
    condition = (!var.shared_account || length(var.protected_state_buckets) > 0) && alltrue([
      for name in var.protected_state_buckets : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", name))
    ])
    error_message = "Shared mode requires explicit state bucket names without wildcards."
  }
}
variable "protected_ssm_paths" {
  type        = set(string)
  default     = []
  sensitive   = true
  description = "Exact private SSM parameter paths to protect, including this runtime input. All SSM access outside gate stack watchdog parameters is also denied."
  validation {
    condition = (!var.shared_account || length(var.protected_ssm_paths) > 0) && alltrue([
      for path in var.protected_ssm_paths : can(regex("^/[A-Za-z0-9_./-]+$", path)) && !endswith(path, "/") && !startswith(path, "/honua/honua-gate-")
    ])
    error_message = "Shared mode requires exact private SSM parameter paths without wildcards, outside the /honua/honua-gate-* watchdog namespace that gate stacks may write."
  }
}
variable "budget_alert_email" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Private recipient for the shared-account 80 percent actual-cost alert."
  validation {
    condition     = !var.shared_account || can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.budget_alert_email))
    error_message = "Shared mode requires a private budget alert recipient."
  }
}

variable "idp_callback_urls" {
  type        = set(string)
  default     = ["https://localhost/admin/auth/callback"]
  description = "Static gate HTTPS callback URLs kept on the client. honua-gate-reaper-callbacks adds live gate stack callbacks."
  validation {
    condition = length(var.idp_callback_urls) > 0 && length(var.idp_callback_urls) <= 20 && alltrue([
      for url in var.idp_callback_urls : can(regex("^https://[a-z0-9.-]+/admin/auth/callback$", url)) && !strcontains(url, "*")
    ])
    error_message = "Register one to 20 exact HTTPS /admin/auth/callback URLs without wildcards."
  }
}

variable "idp_task_execution_role_arns" {
  type        = set(string)
  default     = []
  description = "Optional exact gate roles that may fetch the client secret in addition to CloudFormation and the honua-gate-*-ExecutionRole-* pattern."
  validation {
    condition = alltrue([
      for arn in var.idp_task_execution_role_arns : can(regex("^arn:aws:iam::${var.member_account_id}:role/honua-gate-[A-Za-z0-9_+=,.@/-]+$", arn)) && !strcontains(arn, "*")
    ])
    error_message = "Supply only exact gate execution role ARNs in this account; wildcards are forbidden."
  }
}

variable "orphan_cleanup_dry_run" {
  description = "Log orphan gate IAM/KMS cleanup without mutating resources. Main opts in after reviewing the log."
  type        = bool
  default     = true
}

variable "protection_trail_cleanup_dry_run" {
  description = "Log retained honua-protection trail and bucket cleanup without deleting them. Main opts in after review."
  type        = bool
  default     = true
}

variable "temporary_cleanup_vpc_ids" {
  description = "Temporary exact IDs for at most two orphan gate networks; private SSM tfvars only, clear after cleanup."
  type        = set(string)
  default     = []
  sensitive   = true
  validation {
    condition = length(var.temporary_cleanup_vpc_ids) <= 2 && alltrue([
      for id in var.temporary_cleanup_vpc_ids : can(regex("^vpc-([0-9a-f]{8}|[0-9a-f]{17})$", id))
    ])
    error_message = "Supply at most two exact vpc IDs; wildcards and ARNs are forbidden."
  }
  validation {
    condition     = var.shared_account || length(var.temporary_cleanup_vpc_ids) == 0
    error_message = "Temporary cleanup is available only in the shared gate account."
  }
}

variable "temporary_cleanup_gateway_ids" {
  description = "Temporary exact IDs for at most two orphan gate networks; private SSM tfvars only, clear after cleanup."
  type        = set(string)
  default     = []
  sensitive   = true
  validation {
    condition = length(var.temporary_cleanup_gateway_ids) <= 2 && alltrue([
      for id in var.temporary_cleanup_gateway_ids : can(regex("^igw-([0-9a-f]{8}|[0-9a-f]{17})$", id))
    ])
    error_message = "Supply at most two exact igw IDs; wildcards and ARNs are forbidden."
  }
  validation {
    condition     = var.shared_account || length(var.temporary_cleanup_gateway_ids) == 0
    error_message = "Temporary cleanup is available only in the shared gate account."
  }
}

variable "temporary_cleanup_subnet_group_names" {
  description = "One exact orphan gate DB subnet group; private tfvars only, clear immediately after cleanup."
  type        = set(string)
  default     = []
  sensitive   = true
  validation {
    condition = length(var.temporary_cleanup_subnet_group_names) <= 1 && alltrue([
      for name in var.temporary_cleanup_subnet_group_names : can(regex("^honua-gate-[a-z0-9][a-z0-9-]{0,243}$", name))
    ])
    error_message = "Supply at most one exact gate-prefixed subnet group name without wildcards or ARNs."
  }
  validation {
    condition     = var.shared_account || length(var.temporary_cleanup_subnet_group_names) == 0
    error_message = "Temporary subnet cleanup is available only in the shared gate account."
  }
}

variable "gate_test_domain" {
  description = "Delegated test name (three or more labels) for gate domain installs, under a test-only domain; empty creates no zone."
  type        = string
  default     = ""
  validation {
    condition     = var.gate_test_domain == "" || can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.){2,}[a-z]{2,63}$", var.gate_test_domain))
    error_message = "Use a lowercase subdomain name with at least three labels and no trailing dot."
  }
  validation {
    condition     = var.shared_account || var.gate_test_domain == ""
    error_message = "The gate test zone is available only in the shared gate account."
  }
}

variable "gate_test_parent_zone_id" {
  description = "Optional same-account public zone that delegates gate_test_domain; empty leaves delegation manual."
  type        = string
  default     = ""
  validation {
    condition     = var.gate_test_parent_zone_id == "" || can(regex("^Z[A-Z0-9]{1,31}$", var.gate_test_parent_zone_id))
    error_message = "Supply a bare Route 53 hosted zone ID."
  }
  validation {
    condition     = var.gate_test_parent_zone_id == "" || var.gate_test_domain != ""
    error_message = "A parent zone needs gate_test_domain."
  }
}
