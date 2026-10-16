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
