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

variable "state_admin_role_arns" {
  description = "Exact existing Terraform deployment and recovery roles. These remain outside runtime and worker custody."
  type        = set(string)
  validation {
    condition     = length(var.state_admin_role_arns) > 0 && alltrue([for arn in var.state_admin_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", arn))])
    error_message = "Supply at least one exact state administration role ARN without wildcards."
  }
}
