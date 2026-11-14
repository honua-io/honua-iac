variable "member_account_id" {
  type        = string
  description = "Member account identifier from the account stage, delivered through private SSM tfvars."
  validation {
    condition     = can(regex("^[0-9]{12}$", var.member_account_id))
    error_message = "Supply the member account identifier through private tfvars."
  }
}
variable "lane_principal_arns" {
  type        = set(string)
  description = "Exact existing IAM role ARNs allowed to assume the gate lane role, from private SSM tfvars."
  validation {
    condition     = length(var.lane_principal_arns) > 0 && alltrue([for arn in var.lane_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9_+=,.@/-]+$", arn)) && !strcontains(arn, "*")])
    error_message = "Trust at least one exact IAM role ARN; account roots and wildcards are forbidden."
  }
}
