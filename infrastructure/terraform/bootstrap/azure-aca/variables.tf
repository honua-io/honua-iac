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
  description = "The scope for the role assignment. Defaults to the current subscription. Recommended: set to a specific resource group ID."
  type        = string
  default     = ""

  validation {
    condition     = var.scope == "" || can(regex("^/subscriptions/", var.scope))
    error_message = "scope must be empty (for subscription) or a valid Azure resource scope starting with /subscriptions/."
  }
}

variable "service_principal_secret_duration_hours" {
  type        = number
  description = "Lifetime in hours for the bootstrap service principal secret."
  default     = 720
}

variable "create_client_secret" {
  type        = bool
  description = "Emit a client secret for the Terraform application. Keep false for workload identity/federation-first bootstrap."
  default     = false
}

variable "federated_issuer" {
  type        = string
  description = "OIDC issuer URL for workload identity federation. Leave empty to skip federated credential creation."
  default     = ""
}

variable "federated_subject" {
  type        = string
  description = "OIDC subject claim allowed to exchange tokens for the Terraform application."
  default     = ""
}

variable "federated_audiences" {
  type        = list(string)
  description = "Allowed OIDC audiences for workload identity federation."
  default     = ["api://AzureADTokenExchange"]
}

variable "federated_credential_display_name" {
  type        = string
  description = "Display name for the optional workload identity federated credential."
  default     = "terraform-workload"
}
