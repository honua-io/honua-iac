variable "region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  description = "amd64 instance type for the build host. Compute-optimised; 16 vCPU and 32 GiB fit one full .NET server build and test run."
  type        = string
  default     = "c7i.4xlarge"
}

variable "root_volume_gib" {
  description = "Build disk size. Server builds and test containers write tens of GiB per run."
  type        = number
  default     = 300
  validation {
    condition     = var.root_volume_gib >= 100 && var.root_volume_gib <= 1000
    error_message = "root_volume_gib must be between 100 and 1000."
  }
}

variable "allowed_ssh_cidrs" {
  description = "Explicit IPv4 CIDRs allowed to reach SSH; broad internet access is prohibited."
  type        = set(string)
  validation {
    condition = length(var.allowed_ssh_cidrs) > 0 && alltrue([
      for cidr in var.allowed_ssh_cidrs : can(cidrnetmask(cidr)) && try(tonumber(split("/", cidr)[1]) > 0, false)
    ])
    error_message = "Supply valid IPv4 CIDRs with a prefix greater than zero."
  }
}

variable "ssh_public_key" {
  description = "Public key for the ubuntu SSH account."
  type        = string
  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]+( .*)?$", trimspace(var.ssh_public_key)))
    error_message = "Supply an OpenSSH public key."
  }
}

variable "idle_stop_minutes" {
  description = "Stop the host after this many minutes with average CPU below idle_cpu_percent."
  type        = number
  default     = 30
  validation {
    condition     = var.idle_stop_minutes >= 10 && var.idle_stop_minutes % 5 == 0
    error_message = "idle_stop_minutes must be a multiple of 5 and at least 10."
  }
}

variable "idle_cpu_percent" {
  type    = number
  default = 5
}

variable "nightly_stop_cron" {
  description = "EventBridge Scheduler cron expression for the unconditional nightly stop, evaluated in nightly_stop_timezone."
  type        = string
  default     = "cron(0 2 * * ? *)"
}

variable "nightly_stop_timezone" {
  type    = string
  default = "America/Los_Angeles"
}

variable "monthly_budget_usd" {
  description = "Hard monthly cap for this host's tagged cost. At 100% of actual spend an AWS Budgets action stops the host."
  type        = number
  default     = 75
}

variable "budget_alert_email" {
  description = "Email that AWS Budgets notifies when the cap action runs."
  type        = string
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "Supply an email address."
  }
}
