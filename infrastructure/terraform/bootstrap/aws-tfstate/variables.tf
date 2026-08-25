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

variable "lock_mode" {
  description = <<-EOT
    Terraform state locking primitive.

    "s3_native" (default) uses the S3 backend's `use_lockfile = true` lock
    object and creates no DynamoDB table. It requires Terraform >= 1.10 in the
    roots that consume this backend.

    "dynamodb" creates the legacy lock table for operators pinned below 1.10.

    "both" creates the table and reports S3 native locking, which is the
    two-step migration path between the two.
  EOT
  type        = string
  default     = "s3_native"

  validation {
    condition     = contains(["s3_native", "dynamodb", "both"], var.lock_mode)
    error_message = "lock_mode must be one of: s3_native, dynamodb, both."
  }
}

variable "state_key_scopes" {
  description = <<-EOT
    Additional stack/environment scopes served by this bucket. Each entry gets
    its own exclusive object key; two scopes can never share one key. Leave
    empty to serve only the stack_name/environment pair above.
  EOT
  type = list(object({
    stack_name  = string
    environment = string
  }))
  default = []

  validation {
    condition = length(var.state_key_scopes) == length(distinct([
      for scope in var.state_key_scopes : "${scope.stack_name}/${scope.environment}"
    ]))
    error_message = "state_key_scopes must not contain duplicate stack_name/environment pairs."
  }
}

variable "create_backend_access_policy" {
  description = "Create the least-privilege managed policy that grants access to the state objects and lock only."
  type        = bool
  default     = true
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
