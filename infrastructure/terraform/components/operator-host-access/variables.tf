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

variable "budget_alert_email" {
  description = "Email that receives the cost alerts."
  type        = string
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "Supply an email address."
  }
}
