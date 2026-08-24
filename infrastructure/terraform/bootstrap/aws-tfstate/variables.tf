variable "aws_region" {
  description = "AWS region for the state bucket and lock table."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid 3-63 character S3 bucket name."
  }
}

variable "lock_table_name" {
  description = "DynamoDB table name used for Terraform state locking."
  type        = string
  default     = "honua-tfstate-lock"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]{3,255}$", var.lock_table_name))
    error_message = "lock_table_name must contain only letters, digits, underscore, period, or hyphen."
  }
}

variable "stack_name" {
  description = "Stack namespace used in the evidence-safe state key."
  type        = string
  default     = "aws"
}

variable "environment" {
  description = "Environment namespace used in the evidence-safe state key."
  type        = string
  default     = "prod"
}

variable "kms_key_arn" {
  description = "Optional customer-managed KMS key ARN. AES256 S3 encryption is used when omitted."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags for the state resources."
  type        = map(string)
  default     = {}
}
