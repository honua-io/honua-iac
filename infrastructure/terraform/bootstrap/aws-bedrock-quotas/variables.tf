variable "region" {
  description = "Region whose Bedrock quotas are raised. Cross-region and global inference profiles are metered against the source region."
  type        = string
  default     = "us-east-1"
}

variable "opus_5_5_tokens_per_minute" {
  description = "Tokens per minute for Claude Opus 5.5, applied to both the US cross-region and the global inference profile. 0 leaves the quota unmanaged."
  type        = number
  default     = 2000000
  validation {
    condition     = var.opus_5_5_tokens_per_minute >= 0 && var.opus_5_5_tokens_per_minute <= 10000000
    error_message = "opus_5_5_tokens_per_minute must be between 0 and 10,000,000."
  }
}

variable "sonnet_5_5_tokens_per_minute" {
  description = "Tokens per minute for Claude Sonnet 5.5, applied to both the US cross-region and the global inference profile. 0 leaves the quota unmanaged."
  type        = number
  default     = 2000000
  validation {
    condition     = var.sonnet_5_5_tokens_per_minute >= 0 && var.sonnet_5_5_tokens_per_minute <= 10000000
    error_message = "sonnet_5_5_tokens_per_minute must be between 0 and 10,000,000."
  }
}
