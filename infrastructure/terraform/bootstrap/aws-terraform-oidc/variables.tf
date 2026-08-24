variable "aws_region" {
  type        = string
  description = "AWS region containing the Terraform state resources."
  default     = "us-east-1"
}

variable "role_name" {
  type        = string
  description = "Name of the short-lived Terraform backend access role."
  default     = "honua-terraform-backend"
}

variable "oidc_provider_arn" {
  type        = string
  description = "Existing IAM OIDC provider ARN trusted for backend sessions."

  validation {
    condition     = can(regex("^arn:[^:]+:iam::[0-9]{12}:oidc-provider/.+$", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must be an IAM OIDC provider ARN."
  }
}

variable "oidc_provider_url" {
  type        = string
  description = "Issuer URL corresponding to oidc_provider_arn."

  validation {
    condition     = can(regex("^https://[^/]+(?:/.*)?$", var.oidc_provider_url))
    error_message = "oidc_provider_url must be an HTTPS issuer URL."
  }
}

variable "oidc_subject" {
  type        = string
  description = "Exact OIDC subject allowed to assume the backend role."

  validation {
    condition     = length(trimspace(var.oidc_subject)) > 0
    error_message = "oidc_subject must not be empty."
  }
}

variable "oidc_audience" {
  type        = string
  description = "Exact OIDC audience allowed to assume the backend role."
  default     = "sts.amazonaws.com"
}

variable "state_bucket_arn" {
  type        = string
  description = "ARN of the separately bootstrapped Terraform state bucket."
}

variable "state_lock_table_arn" {
  type        = string
  description = "ARN of the separately bootstrapped Terraform lock table."
}

variable "max_session_duration" {
  type        = number
  description = "Maximum lifetime of an STS web-identity session in seconds."
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 900 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 900 and 43200 seconds."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the IAM role."
  default     = {}
}
