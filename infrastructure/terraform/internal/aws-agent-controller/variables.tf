variable "region" {
  type    = string
  default = "us-east-1"
}

variable "account_id" {
  description = "Reviewed AWS account; the provider rejects other accounts."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Supply an exact AWS account ID."
  }
}

variable "candidate_digest" {
  description = "One accounting history for all development, retries and qualification of this candidate."
  type        = string
  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.candidate_digest))
    error_message = "Bind the exact candidate component digest."
  }
}

variable "controller_role_arn" {
  description = "Existing trusted controller role, never a worker, lifecycle or approver role."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", var.controller_role_arn))
    error_message = "Supply one exact IAM role ARN without wildcards."
  }
}

variable "claim_writer_role_arns" {
  description = "Exact Terraform-defined worker lifecycle roles with fixed conditional PutItem state machines; never controller or worker roles. Empty disables runtime launches."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for arn in var.claim_writer_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/honua-agent-[a-z0-9-]{3,40}-lifecycle$", arn))])
    error_message = "Only exact worker lifecycle role ARNs from the aws-agent-worker root may create launch claims."
  }
}

variable "state_admin_role_arns" {
  description = "Exact existing Terraform deployment and recovery roles. These remain outside runtime and worker custody."
  type        = set(string)
  validation {
    condition     = length(var.state_admin_role_arns) > 0 && alltrue([for arn in var.state_admin_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", arn))])
    error_message = "Supply at least one exact state administration role ARN without wildcards."
  }
}

variable "installed_worker_slots" {
  description = "Optional exact installed allocations. Empty preserves legacy claims policy. The immutable slot state machines and controller identity policy must be reviewed together."
  type        = list(object({ runtime_id = string, slot_id = string }))
  default     = []
  validation {
    condition = length(var.installed_worker_slots) <= 4 && length(distinct([for slot in var.installed_worker_slots : slot.slot_id])) == length(var.installed_worker_slots) && alltrue([
      for slot in var.installed_worker_slots : can(regex("^[A-Za-z0-9_-]{1,128}$", slot.runtime_id)) && can(regex("^[a-z0-9-]{3,40}$", slot.slot_id))
    ])
    error_message = "Review at most four distinct fixed physical slots and exact runtime IDs."
  }
}

variable "installed_runtime_controllers" {
  description = "Optional dedicated installed pollers, each bound to one existing installed runtime. These are runtime principals, never state administrators or lifecycle claim writers. Empty preserves legacy authority."
  type        = list(object({ runtime_id = string, role_arn = string }))
  default     = []
  validation {
    condition = length(var.installed_runtime_controllers) <= 4 && length(distinct([for controller in var.installed_runtime_controllers : controller.role_arn])) == length(var.installed_runtime_controllers) && alltrue([
      for controller in var.installed_runtime_controllers : can(regex("^[A-Za-z0-9_-]{1,128}$", controller.runtime_id)) && can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", controller.role_arn))
    ])
    error_message = "Bind at most four distinct exact installed controller roles to reviewed runtime IDs."
  }
}
