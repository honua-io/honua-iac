variable "aws_region" {
  description = "AWS region the deployment role is allowed to operate in."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for the roles and policies created by this root."
  type        = string
  default     = "honua"
}

variable "environment" {
  description = "Environment name used in role names and tags."
  type        = string
  default     = "prod"
}

variable "trust_mode" {
  description = <<-EOT
    How the deployment role is reached.

    "oidc"  federate a CI/workload OIDC provider through
            sts:AssumeRoleWithWebIdentity (no long-lived credential exists).
    "sso"   let an existing IAM Identity Center / SSO permission set or another
            already-federated principal call sts:AssumeRole.
    "both"  accept either.

    There is no mode that accepts a long-lived IAM user.
  EOT
  type        = string
  default     = "oidc"

  validation {
    condition     = contains(["oidc", "sso", "both"], var.trust_mode)
    error_message = "trust_mode must be one of: oidc, sso, both."
  }
}

variable "oidc_provider_arn" {
  description = "Existing IAM OIDC provider ARN trusted to assume the deployment role. Required when trust_mode includes oidc."
  type        = string
  default     = ""
}

variable "oidc_provider_url" {
  description = "Issuer URL matching oidc_provider_arn, e.g. https://token.actions.githubusercontent.com."
  type        = string
  default     = ""
}

variable "oidc_subjects" {
  description = "Exact OIDC subjects allowed to assume the deployment role. Wildcards are permitted but discouraged."
  type        = list(string)
  default     = []
}

variable "oidc_audience" {
  description = "OIDC audience required in the token."
  type        = string
  default     = "sts.amazonaws.com"
}

variable "trusted_principal_arns" {
  description = "Already-federated principals (SSO permission-set roles, workload roles) allowed to assume the deployment role. Required when trust_mode includes sso."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.trusted_principal_arns : !can(regex("^arn:[^:]+:iam::[0-9]{12}:user/", arn))
    ])
    error_message = "trusted_principal_arns must not contain IAM user principals; the certified path federates through STS."
  }
}

variable "max_session_duration" {
  description = "Maximum lifetime of a deployment session, in seconds."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 900 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 900 and 43200 seconds."
  }
}

variable "state_bucket_arn" {
  description = "ARN of the Terraform state bucket from bootstrap/aws-tfstate. The deployment role is explicitly denied access to it."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:s3:::", var.state_bucket_arn))
    error_message = "state_bucket_arn must be an S3 bucket ARN."
  }
}

variable "state_lock_table_arn" {
  description = "ARN of the DynamoDB lock table, when lock_mode is dynamodb. Empty when locking on the S3 native lockfile."
  type        = string
  default     = ""
}

variable "backend_access_role_arn" {
  description = "ARN of the separate backend access role (bootstrap/aws-terraform-oidc). Recorded in the identity contract and asserted distinct from the deployment role."
  type        = string
  default     = ""
}

variable "backend_access_policy_arn" {
  description = "ARN of the least-privilege backend access policy emitted by bootstrap/aws-tfstate."
  type        = string
  default     = ""
}

variable "task_execution_role_name_prefix" {
  description = "Name prefix of the ECS task EXECUTION roles the deployment role may pass. These pull images and fetch secrets; they are not the application identity."
  type        = string
  default     = "honua-"
}

variable "app_runtime_role_name_prefix" {
  description = "Name prefix of the application RUNTIME (ECS task) roles the deployment role may pass."
  type        = string
  default     = "honua-"
}

variable "task_execution_role_arn" {
  description = "Optional exact ECS task execution role ARN, recorded in the identity contract for separation evidence."
  type        = string
  default     = ""
}

variable "app_runtime_role_arn" {
  description = "Optional exact application runtime role ARN, recorded in the identity contract for separation evidence."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to the roles and policies."
  type        = map(string)
  default     = {}
}
