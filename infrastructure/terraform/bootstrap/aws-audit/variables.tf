variable "alert_email" {
  description = "Address that receives change, drift and audit-cost alerts (the build host budget address)."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "Supply an email address."
  }
}

variable "home_region" {
  description = "Region of the trail, the audit bucket, the alert topic and the global-resource recorder."
  type        = string
  default     = "us-east-1"
}

variable "recorded_regions" {
  description = "Regions with an AWS Config recorder and a change-alert rule."
  type        = set(string)
  default     = ["us-east-1", "eu-north-1", "us-west-2"]
  validation {
    condition     = contains(var.recorded_regions, var.home_region)
    error_message = "recorded_regions must include home_region, which records the global resource types."
  }
}

variable "stack_drift_regions" {
  description = "Regions where CloudFormation stacks run and the stack drift rule evaluates them."
  type        = set(string)
  default     = ["us-east-1", "us-west-2"]
  validation {
    condition     = length(setsubtract(var.stack_drift_regions, var.recorded_regions)) == 0
    error_message = "stack_drift_regions must be recorded_regions: the rule needs the stack resource type recorded."
  }
}

variable "standard_retention_days" {
  description = "Days audit objects stay in S3 Standard before moving to Glacier Instant Retrieval."
  type        = number
  default     = 90
}

variable "retention_days" {
  description = "Days audit objects are kept before they expire."
  type        = number
  default     = 365
  validation {
    condition     = var.retention_days > var.standard_retention_days
    error_message = "retention_days must exceed standard_retention_days."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly AWS Config plus CloudTrail cost that emails alert_email (80% actual, 100% forecast)."
  type        = number
  default     = 50
}
