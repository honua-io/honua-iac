variable "aws_region" {
  type        = string
  description = "AWS region to scope support-access role permissions to."
  default     = "us-east-1"
}

variable "name_prefix" {
  type        = string
  description = "Prefix applied to the support-access role and policy names."
  default     = "Honua"
}

variable "support_principal_arns" {
  type        = list(string)
  description = <<-EOT
    ARNs of the trusted Honua support principals (the IAM roles/users in the
    Honua support account that operators assume these roles from). Cross-account
    role assumption is used instead of long-lived access keys. At least one ARN
    is required so the trust policy is never left open.
  EOT

  validation {
    condition     = length(var.support_principal_arns) > 0
    error_message = "Provide at least one trusted Honua support principal ARN; an empty trust policy is not allowed."
  }

  validation {
    condition     = alltrue([for arn in var.support_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(root|user/.+|role/.+)$", arn))])
    error_message = "Each support principal must be a valid IAM ARN (arn:aws:iam::<account-id>:root|user/...|role/...)."
  }
}

variable "external_id" {
  type        = string
  description = <<-EOT
    Shared secret required on every AssumeRole call (the AWS confused-deputy
    guardrail for third-party access). Honua support provides this per customer;
    treat it as a secret and never reuse it across accounts.
  EOT

  validation {
    condition     = length(var.external_id) >= 16
    error_message = "external_id must be at least 16 characters to provide meaningful entropy."
  }
}

variable "observe_max_session_duration" {
  type        = number
  description = "Maximum session duration (seconds) for the read-only observe role. AWS allows 3600-43200."
  default     = 3600

  validation {
    condition     = var.observe_max_session_duration >= 3600 && var.observe_max_session_duration <= 43200
    error_message = "observe_max_session_duration must be between 3600 and 43200 seconds."
  }
}

variable "break_glass_max_session_duration" {
  type        = number
  description = <<-EOT
    Maximum session duration (seconds) for the elevated break-glass role. Kept
    deliberately short so remediation sessions expire on their own. AWS allows
    3600-43200; the default of 3600 (1 hour) is recommended for ticket-scoped
    remediation.
  EOT
  default     = 3600

  validation {
    condition     = var.break_glass_max_session_duration >= 3600 && var.break_glass_max_session_duration <= 14400
    error_message = "break_glass_max_session_duration must be between 3600 and 14400 seconds (1-4 hours) to keep break-glass sessions short."
  }
}

variable "require_mfa" {
  type        = bool
  description = <<-EOT
    Require the assuming session to be MFA-authenticated (aws:MultiFactorAuthPresent).
    Recommended for the break-glass role. Leave enabled unless the support
    principal cannot present MFA in its assume-role chain.
  EOT
  default     = true
}

variable "require_session_tags" {
  type        = bool
  description = <<-EOT
    Require ticket/incident/operator session tags on AssumeRole so every session
    is auditable in CloudTrail. When true, callers must pass aws:RequestTag for
    HonuaTicketId and HonuaOperator.
  EOT
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the support-access roles and policies."
  default     = {}
}
