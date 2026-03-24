variable "aws_region" {
  type        = string
  description = "AWS region to create the IAM user in."
  default     = "us-east-1"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for the Terraform IAM user name."
  default     = "honua-terraform"
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

variable "role_name" {
  type        = string
  description = "Override for the federated IAM role name."
  default     = ""
}

variable "create_iam_user" {
  type        = bool
  description = "Create the legacy IAM user fallback surface. Leave false to prefer OIDC/workload identity federation."
  default     = false
}

variable "create_access_key" {
  type        = bool
  description = "Whether to create an access key for the IAM user."
  default     = false
}

variable "oidc_provider_arn" {
  type        = string
  description = "Existing IAM OIDC provider ARN allowed to assume the federated Terraform role."
  default     = ""
}

variable "oidc_subjects" {
  type        = list(string)
  description = "OIDC subject claims allowed to assume the federated Terraform role."
  default     = []
}

variable "oidc_audiences" {
  type        = list(string)
  description = "OIDC audience claims allowed to assume the federated Terraform role."
  default     = ["sts.amazonaws.com"]
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to the IAM user and policy."
  default     = {}
}
