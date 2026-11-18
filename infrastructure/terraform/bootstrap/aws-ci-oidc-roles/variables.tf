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

variable "bedrock_regions" {
  description = "Regions the us.* cross-Region inference profiles route to. The Bedrock roles may invoke models only there."
  type        = list(string)
  default     = ["us-east-1", "us-east-2", "us-west-1", "us-west-2"]
  validation {
    condition     = length(var.bedrock_regions) > 0 && alltrue([for region in var.bedrock_regions : can(regex("^us-[a-z]+-[0-9]$", region))])
    error_message = "bedrock_regions must be exact US Region names."
  }
}

variable "inventory_role_name" {
  description = "Role whose single inline policy the honua-iac release-cell-inventory-policy workflow reviews and applies (honua-release tools/cloud_cell_inventory_policy.py ROLE)."
  type        = string
  default     = "honua-release-cicd"
}
