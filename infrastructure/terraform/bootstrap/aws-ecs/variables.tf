variable "aws_region" {
  type        = string
  description = "AWS region to create the IAM user in."
  default     = "us-east-1"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for the Terraform IAM user name. The default names the posture: this path is local-only and unsupported for release."
  default     = "honua-local-unsupported"
}

variable "environment" {
  type        = string
  description = "Environment name used in the IAM user name."
  default     = "dev"
}

variable "user_name" {
  type        = string
  description = "Override for the IAM user name."
  default     = ""
}

variable "create_access_key" {
  type        = bool
  description = "Whether to mint a long-lived access key. Leave false. Setting it true emits a plan-time warning and can never satisfy the release lane."
  default     = false

  validation {
    condition     = !var.create_access_key
    error_message = "create_access_key must remain false; this bootstrap is local-only and unsupported for the release lane."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to the IAM user and policy."
  default     = {}
}
