variable "region" {
  description = "Region the IAM resources are managed from (IAM itself is global)."
  type        = string
  default     = "us-east-1"
}

variable "oidc_provider_arn" {
  description = "ARN of the existing token.actions.githubusercontent.com OIDC provider (this root never creates it)."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must be the GitHub Actions OIDC provider of this account."
  }
}

variable "oidc_subjects" {
  description = <<-EOT
    Exact subjects allowed to assume the publish role. Default: honua-server jobs
    in the publish-images environment, whose deployment policy admits only
    trunk, release/* and the publication tags. honua-server uses the default
    (name-form) subject; GitHub puts the environment or the ref in `sub`, never both.
  EOT
  type        = list(string)
  default     = ["repo:honua-io/honua-server:environment:publish-images"]
  validation {
    condition = length(var.oidc_subjects) > 0 && alltrue([
      for subject in var.oidc_subjects : can(regex("^repo:honua-io/honua-server:environment:publish-[a-z-]+$", subject))
    ])
    error_message = "Only honua-server publish-* environment subjects may assume the publish role (no branch, tag, wildcard, pull_request or other repository subjects)."
  }
}

variable "role_name" {
  description = "Name of the publish role. honua-server deploy.yml and deploy-platform-images.yml assume it by this name."
  type        = string
  default     = "honua-server-gha-ecr-publish"
}

variable "ecr_region" {
  description = "Region of the publication repositories (honua-server variable AWS_ECR_REGION)."
  type        = string
  default     = "us-west-2"
}

variable "repository_names" {
  description = "ECR repositories the publish jobs push to (honua-server variable AWS_ECR_REPOSITORY)."
  type        = list(string)
  default     = ["honua-server"]
  validation {
    condition     = length(var.repository_names) > 0 && alltrue([for name in var.repository_names : can(regex("^[a-z0-9][a-z0-9._/-]*$", name))])
    error_message = "repository_names must be exact ECR repository names (no wildcards)."
  }
}
