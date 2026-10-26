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
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to the IAM user and policy."
  default     = {}
}

variable "workload_name_prefix" {
  type        = string
  description = "Name prefix of the IAM roles and policies the deployed stack creates (the example's name_prefix, e.g. honuasl for examples/aws-serverless). The deploy user may create, edit, pass and delete IAM only under role/<prefix>* and policy/<prefix>*."
  default     = "honua"

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{3,}$", var.workload_name_prefix))
    error_message = "workload_name_prefix must be at least 3 IAM name characters and must not contain wildcards."
  }
}

variable "protected_role_arns" {
  type        = list(string)
  description = "Additional role ARNs (wildcards allowed) the deploy user must never pass, edit or delete, even when they match workload_name_prefix. The governed *-deploy, *-gha and honua-terraform-backend* roles are always protected."
  default     = []
}
