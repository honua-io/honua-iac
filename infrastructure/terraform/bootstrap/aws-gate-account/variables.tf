variable "management_account_id" {
  type        = string
  description = "Organization management account, from private SSM tfvars."
  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "Supply the management account identifier through private tfvars."
  }
}
variable "parent_id" {
  type        = string
  description = "Existing organization root or OU with SCPs enabled and FullAWSAccess inherited."
  validation {
    condition     = can(regex("^(r-[a-z0-9]+|ou-[a-z0-9]+-[a-z0-9]+)$", var.parent_id))
    error_message = "Supply an organization root or OU identifier."
  }
}
variable "account_email" {
  type        = string
  sensitive   = true
  description = "Unique member-account contact address, supplied only through SSM SecureString."
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.account_email))
    error_message = "Supply a valid private account contact address."
  }
}
variable "budget_alert_email" {
  type        = string
  sensitive   = true
  description = "Private budget-action notification address from SSM SecureString."
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "Supply a valid private notification address."
  }
}
