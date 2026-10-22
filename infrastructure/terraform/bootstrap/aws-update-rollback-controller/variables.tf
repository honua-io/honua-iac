variable "region" {
  description = "Certification region. The release guardrails deny every other region."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Controller role name. Outside the honuar*/honuan*/honuaeks* cell namespaces so no cell or reaper can own it."
  type        = string
  default     = "honua-release-update-rollback-controller"
  validation {
    condition     = can(regex("^[A-Za-z0-9_+=,.@-]{1,64}$", var.name)) && !can(regex("^honua(r|n|eks)", var.name))
    error_message = "name must be a valid IAM role name outside the honuar*/honuan*/honuaeks* cell namespaces."
  }
}

variable "assuming_role_arn" {
  description = "The provisioning identity whose job assumes this role (e2e update_rollback_aws.controller_credentials)."
  type        = string
  default     = "arn:aws:iam::585192672263:role/honua-release-cicd"
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", var.assuming_role_arn))
    error_message = "assuming_role_arn must be an IAM role ARN."
  }
}

variable "session_name" {
  description = "The only role session name the producer uses."
  type        = string
  default     = "honua-update-rollback-controller"
}

variable "lambda_function_prefixes" {
  description = "Cell Lambda name prefixes the honua-gitops-aws-lambda backend may switch (alias read/update only)."
  type        = list(string)
  default     = ["honuar", "honuan"]
}
