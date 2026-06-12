variable "region" {
  description = "AWS region for the forms router."
  type        = string
  default     = "us-west-2"
}

variable "name_prefix" {
  description = "Name prefix for all forms-router resources."
  type        = string
  default     = "honua-gtm-forms-router"
}

variable "allowed_origin" {
  description = "Single origin allowed by CORS on the function URL."
  type        = string
  default     = "https://honua.io"
}

variable "attio_secret_name" {
  description = "Secrets Manager secret name holding the Attio API key. The value is set out of band; Terraform only manages a placeholder."
  type        = string
  default     = "honua/gtm/attio-api-key"
}

variable "attio_waitlist_list" {
  description = "Attio list slug (or UUID) for the Cloud Waitlist list."
  type        = string
  default     = "cloud_waitlist"
}

variable "attio_newsletter_list" {
  description = "Attio list slug (or UUID) for the Newsletter list."
  type        = string
  default     = "newsletter"
}

variable "loops_api_key" {
  description = "Optional Loops.so API key. When empty the Loops code path is disabled."
  type        = string
  default     = ""
  sensitive   = true
}

variable "reserved_concurrency" {
  description = "Reserved concurrent executions for the Lambda (conservative throttle)."
  type        = number
  default     = 10
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the Lambda log group."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    project = "honua-gtm"
    stack   = "forms-router"
  }
}
