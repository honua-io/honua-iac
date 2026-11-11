variable "region" {
  description = "Region of the runner host; also where the GitHub App credential parameters live."
  type        = string
  default     = "eu-north-1"
}

variable "runner_group" {
  description = "Organization runner group the runners join. It must already exist and grant the repositories that use the honua-light label."
  type        = string
  default     = "honua-light"
}

variable "runner_count" {
  description = "Concurrent one-job runners on the host, each an unprivileged account with its own rootless Docker and resource slice."
  type        = number
  default     = 12
  validation {
    condition     = var.runner_count >= 1 && var.runner_count <= 16
    error_message = "runner_count must be between 1 and 16."
  }
}

variable "runner_cpu_quota_percent" {
  description = "CPU ceiling per runner, including its containers (100 = one vCPU). 12 x 250 fills a 32 vCPU host."
  type        = number
  default     = 250
  validation {
    condition     = var.runner_cpu_quota_percent >= 100 && var.runner_cpu_quota_percent <= 800
    error_message = "runner_cpu_quota_percent must be between 100 and 800."
  }
}

variable "runner_memory_max_gib" {
  description = "Memory ceiling per runner, including its containers. 12 x 5 GiB leaves headroom on a 64 GiB host."
  type        = number
  default     = 5
  validation {
    condition     = var.runner_memory_max_gib >= 2 && var.runner_memory_max_gib <= 16
    error_message = "runner_memory_max_gib must be between 2 and 16."
  }
}

variable "instance_types" {
  description = "Equivalent amd64 Spot pools of about 32 vCPU and at least 64 GiB."
  type        = list(string)
  default = [
    "c7i.8xlarge", "c6i.8xlarge", "c6in.8xlarge", "c5.9xlarge", "c5a.8xlarge", "c7a.8xlarge",
    "m5.8xlarge", "m6i.8xlarge", "m7i.8xlarge", "m7a.8xlarge", "c7i-flex.8xlarge", "m7i-flex.8xlarge"
  ]
}

variable "root_volume_gib" {
  description = "Shared disk for every runner's home, checkout and rootless Docker data."
  type        = number
  default     = 200
  validation {
    condition     = var.root_volume_gib >= 50 && var.root_volume_gib <= 1000
    error_message = "root_volume_gib must be between 50 and 1000."
  }
}

variable "github_app_id_parameter" {
  description = "Existing SSM String parameter holding the GitHub App id that mints runner registrations."
  type        = string
  default     = "/honua/lane-host/bot-app-id"
}

variable "github_app_key_parameter" {
  description = "Existing SSM SecureString holding that App's private key. Read ephemerally; never stored in state."
  type        = string
  default     = "/honua/lane-host/bot-app-key"
}

variable "github_app_credential_version" {
  description = "Increase to copy a rotated App key into the runner credential parameter."
  type        = number
  default     = 1
}

variable "monthly_budget_usd" {
  description = "Monthly EC2 compute cost of the runner instance types in this region that triggers email alerts (80% actual, 100% forecast)."
  type        = number
  default     = 750
}

variable "budget_alert_email" {
  description = "Email that receives the cost alerts."
  type        = string
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "Supply an email address."
  }
}
