variable "region" {
  description = "Region of the lane host; keep it beside the lane build host."
  type        = string
  default     = "eu-north-1"
}

variable "availability_zone" {
  description = "Zone for the instance and its data volume, which must share a zone."
  type        = string
  default     = "eu-north-1a"
}

variable "instance_type" {
  description = "On-demand instance size. Lanes are memory-heavy Node processes; builds run on the build host."
  type        = string
  default     = "m6i.4xlarge"
}

variable "root_volume_gib" {
  description = "Operating system disk; lane data lives on the separate data volume."
  type        = number
  default     = 60
}

variable "data_volume_gib" {
  description = "Persistent volume for worktrees, logs and lane progress files."
  type        = number
  default     = 500
  validation {
    condition     = var.data_volume_gib >= 100 && var.data_volume_gib <= 2000
    error_message = "data_volume_gib must be between 100 and 2000."
  }
}

variable "allowed_ssh_cidrs" {
  description = "Explicit IPv4 CIDRs allowed to reach SSH; broad internet access is prohibited."
  type        = set(string)
}

variable "ssh_public_key" {
  description = "Public key for the ubuntu SSH account."
  type        = string
}

variable "parameter_prefix" {
  description = "SSM path holding the SecureString parameters claude-credentials, github-token and build-ssh-key. They are created outside Terraform so no secret enters state."
  type        = string
  default     = "/honua/lane-host"
  validation {
    condition     = can(regex("^(/[A-Za-z0-9_.-]+)+$", var.parameter_prefix))
    error_message = "Use an absolute SSM path without a trailing slash."
  }
}

variable "claude_code_version" {
  description = "Pinned @anthropic-ai/claude-code npm version."
  type        = string
  default     = "2.1.322"
}

variable "rtk_version" {
  description = "rtk release used by the lanes' command-output compression hook."
  type        = string
  default     = "1.1.0"
}

variable "rtk_sha256" {
  description = "SHA-256 of rtk-x86_64-unknown-linux-musl.tar.gz for rtk_version, from the release checksums.txt."
  type        = string
  default     = "9454ad1b9489daa57ab0a9f4ebe2faaf4dc82b8a0f26c9e5135151abd7c9378d"
}

variable "build_host_group_name" {
  description = "Auto Scaling group of the lane build host (bootstrap/aws-build-host) that lanes wake and reach over SSH."
  type        = string
  default     = "honua-lane-build-host"
}

variable "build_host_ssh_access" {
  description = "Add an SSH rule for the lane host's address to the build host security group."
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  description = "Monthly on-demand compute cost of the lane host that triggers email alerts (80% actual, 100% forecast)."
  type        = number
  default     = 650
}

variable "budget_alert_email" {
  description = "Email that receives the cost alerts."
  type        = string
}
