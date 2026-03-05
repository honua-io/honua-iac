variable "app_name" {
  type        = string
  description = "Azure AD application display name."
  default     = "honua-terraform-aca"
}

variable "role_name" {
  type        = string
  description = "Custom role name for the Terraform service principal."
  default     = "Honua Terraform ACA"
}

variable "scope" {
  description = "The scope for the role assignment. Use a specific resource group ID."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+$", var.scope))
    error_message = "scope must be a resource group scope like /subscriptions/<id>/resourceGroups/<name>."
  }
}

variable "service_principal_secret_duration_hours" {
  type        = number
  description = "Lifetime in hours for the bootstrap service principal secret."
  default     = 720
}
