variable "app_name" {
  type        = string
  description = "Azure AD application display name."
  default     = "honua-terraform-aks"
}

variable "role_name" {
  type        = string
  description = "Custom role name for the Terraform service principal."
  default     = "Honua Terraform AKS"
}

variable "scope" {
  description = "The scope for the role assignment. Defaults to current subscription. Recommended: set to a specific resource group ID."
  type        = string
  default     = ""

  validation {
    condition     = var.scope == "" || can(regex("^/subscriptions/", var.scope))
    error_message = "scope must be empty (for subscription) or a valid Azure resource scope starting with /subscriptions/."
  }
}

variable "create_client_secret" {
  type        = bool
  description = "Emit a static client secret for fallback automation. Leave false to prefer workload identity federation."
  default     = false
}

variable "service_principal_secret_duration_hours" {
  type        = number
  description = "Lifetime of the fallback service principal secret when create_client_secret is true."
  default     = 8760
}

variable "federated_issuer" {
  type        = string
  description = "OIDC issuer URL for workload identity federation."
  default     = ""
}

variable "federated_subject" {
  type        = string
  description = "OIDC subject claim for workload identity federation."
  default     = ""
}

variable "federated_audiences" {
  type        = list(string)
  description = "OIDC audiences allowed to exchange tokens for the Terraform application."
  default     = ["api://AzureADTokenExchange"]
}

variable "federated_credential_display_name" {
  type        = string
  description = "Display name for the optional workload identity federated credential."
  default     = "terraform-workload-identity"
}
