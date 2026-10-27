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

variable "state_bucket_name" {
  description = "The account's Terraform state bucket (bootstrap/aws-tfstate)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be an S3 bucket name."
  }
}

variable "oidc_subjects" {
  description = <<-EOT
    Exact subjects allowed to assume the apply role. Default: the apply job of
    honua-demo-infra .github/workflows/terraform.yml, which runs in the protected
    `demo` environment (required reviewers, trunk-only deployment-branch policy).
  EOT
  type        = list(string)
  default     = ["repo:honua-io/honua-demo-infra:environment:demo"]
  validation {
    condition = length(var.oidc_subjects) > 0 && alltrue([
      for subject in var.oidc_subjects : can(regex("^repo:honua-io/honua-demo-infra:environment:[A-Za-z0-9_.-]+$", subject))
    ])
    error_message = "Only exact honua-io/honua-demo-infra environment subjects may assume the apply role (no wildcards, no branch or pull_request subjects)."
  }
}

variable "role_name" {
  description = "Name of the apply role. Keep the -gha suffix: it is denied editing any *-gha role, including itself."
  type        = string
  default     = "honua-demo-infra-deploy-gha"
}

variable "max_session_duration_seconds" {
  description = "Maximum session. An apply that modifies RDS or CloudFront can take tens of minutes; the job requests 7200 seconds."
  type        = number
  default     = 7200
}

variable "state_key" {
  description = "State object of the one stack the apply workflow applies (honua-demo-infra stacks/aws)."
  type        = string
  default     = "demo/aws-demo/terraform.tfstate"
}

variable "demo_region" {
  description = "Region of the demo.honua.io resources."
  type        = string
  default     = "us-west-2"
}

variable "name_prefix" {
  description = "Name prefix of every demo resource the stack creates (<name_prefix>-<environment> in the stack)."
  type        = string
  default     = "honua-demo-demo"
}

variable "secret_name_prefixes" {
  description = "Name prefixes of the Terraform-managed demo secrets."
  type        = list(string)
  default     = ["honua-demo-demo/", "honua-demo/demo/"]
}

variable "denied_secret_names" {
  description = "Operator-owned secrets the role may never read or change (Terraform only references them by ARN)."
  type        = list(string)
  default     = ["honua-demo-demo/operation-key-ring"]
}

variable "data_bucket_name_prefix" {
  description = "Prefix of the demo FileStorage/data bucket (honua-demo-data-<account>)."
  type        = string
  default     = "honua-demo-data-"
}

variable "hosted_zone_name" {
  description = "Public Route 53 zone of the demo. The role may change records in this zone only (its id is looked up, not committed)."
  type        = string
  default     = "demo.honua.io"
}

variable "image_repository_names" {
  description = "ECR repositories the serving Lambda pulls from (us-west-2). Lambda image create/update needs BatchGetImage on them, and the module manages one repository policy."
  type        = list(string)
  default     = ["honua-server"]
}
