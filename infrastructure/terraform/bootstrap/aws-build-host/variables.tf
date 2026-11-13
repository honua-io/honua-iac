variable "region" {
  description = "Example region; select the deployment region by current spot price and set it explicitly."
  type        = string
  default     = "us-east-1"
}

variable "root_volume_gib" {
  description = "Build disk size. Server builds and test containers write tens of GiB per run."
  type        = number
  default     = 500
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
  description = "Scale the group to zero after this many minutes without observed build activity."
  type        = number
  default     = 30
  validation {
    condition     = var.idle_stop_minutes >= 10 && var.idle_stop_minutes % 5 == 0
    error_message = "idle_stop_minutes must be a multiple of 5 and at least 10."
  }
}

variable "nightly_stop_enabled" {
  description = "Stop the host unconditionally every night. Off by default: lanes build overnight, and a scheduled stop interrupts running builds. The idle stop already ends billing when the host is unused."
  type        = bool
  default     = false
}

variable "nightly_stop_cron" {
  description = "EventBridge Scheduler cron expression for the unconditional nightly stop, evaluated in nightly_stop_timezone. Avoid 02:00 local, which does not exist on the spring daylight-saving change."
  type        = string
  default     = "cron(0 3 * * ? *)"
}

variable "nightly_stop_timezone" {
  type    = string
  default = "America/Los_Angeles"
}

variable "monthly_budget_usd" {
  description = "Monthly EC2 compute cost that triggers email alerts (80% actual, 100% forecast). Alerts lag several hours and do not stop the host."
  type        = number
  default     = 75
}

variable "budget_alert_email" {
  description = "Email that receives the EC2 cost alerts."
  type        = string
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "Supply an email address."
  }
}

variable "gate_runner_enabled" {
  description = "Register ephemeral GitHub Actions runners for the honua-server PR Gate on this host. Requires the GitHub App credential in the gate runner parameter and the organization runner group described in the README."
  type        = bool
  default     = false
}

variable "gate_runner_repository" {
  description = "The only repository whose pull_request workflows may assume the wake role; its owner is the organization the runners register with."
  type        = string
  default     = "honua-io/honua-server"
  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.gate_runner_repository))
    error_message = "Use owner/repository."
  }
}

variable "gate_runner_count" {
  description = "Concurrent gate jobs on the host, each in its own unprivileged account and resource slice."
  type        = number
  default     = 2
  validation {
    condition     = var.gate_runner_count >= 1 && var.gate_runner_count <= 4
    error_message = "gate_runner_count must be between 1 and 4."
  }
}

variable "gate_runner_cpu_quota_percent" {
  description = "CPU ceiling per gate runner, including its Docker containers (100 = one vCPU). The default leaves lane builds at least four vCPUs while two gate jobs run."
  type        = number
  default     = 600
  validation {
    condition     = var.gate_runner_cpu_quota_percent >= 100 && var.gate_runner_cpu_quota_percent <= 1600
    error_message = "gate_runner_cpu_quota_percent must be between 100 and 1600."
  }
}

variable "gate_runner_memory_max_gib" {
  description = "Memory ceiling per gate runner, including its Docker containers."
  type        = number
  default     = 16
  validation {
    condition     = var.gate_runner_memory_max_gib >= 4 && var.gate_runner_memory_max_gib <= 24
    error_message = "gate_runner_memory_max_gib must be between 4 and 24."
  }
}

variable "heavy_runner_count" {
  description = "Ephemeral runners for honua-server heavy test shards (label honua-heavy, runner group honua-heavy), added only when gate_runner_enabled is true. Requires the runner group described in the README."
  type        = number
  default     = 8
  validation {
    condition     = var.heavy_runner_count >= 0 && var.heavy_runner_count <= 8
    error_message = "heavy_runner_count must be between 0 and 8."
  }
}

variable "heavy_runner_cpu_quota_percent" {
  description = "CPU ceiling per heavy runner, including its Docker containers (100 = one vCPU). Eight runners at the default are ceilings, not reservations: measured use on the 64-vCPU host stays well below them."
  type        = number
  default     = 800
  validation {
    condition     = var.heavy_runner_cpu_quota_percent >= 100 && var.heavy_runner_cpu_quota_percent <= 1600
    error_message = "heavy_runner_cpu_quota_percent must be between 100 and 1600."
  }
}

variable "heavy_runner_memory_max_gib" {
  description = "Memory ceiling per heavy runner, including its Docker containers. The default matches a GitHub-hosted runner."
  type        = number
  default     = 16
  validation {
    condition     = var.heavy_runner_memory_max_gib >= 4 && var.heavy_runner_memory_max_gib <= 24
    error_message = "heavy_runner_memory_max_gib must be between 4 and 24."
  }
}

variable "runner_min_free_disk_gib" {
  description = "A runner takes its next job only while the root volume has at least this much free space; lane builds share the disk."
  type        = number
  default     = 40
  validation {
    condition     = var.runner_min_free_disk_gib >= 10 && var.runner_min_free_disk_gib <= 200
    error_message = "runner_min_free_disk_gib must be between 10 and 200."
  }
}
