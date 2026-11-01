variable "region" {
  type    = string
  default = "us-east-1"
}
variable "host_count" {
  type    = number
  default = 4
  validation {
    condition     = var.host_count >= 1 && var.host_count <= 20 && floor(var.host_count) == var.host_count
    error_message = "host_count must be an integer between 1 and 20."
  }
}
variable "instance_type" {
  type    = string
  default = "c6i.4xlarge"
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
  description = "Public key used for the ubuntu SSH account."
  type        = string
  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]+( .*)?$", trimspace(var.ssh_public_key)))
    error_message = "Supply an OpenSSH public key."
  }
}
variable "ttl_hours" {
  type    = number
  default = 36
  validation {
    condition     = var.ttl_hours > 0 && floor(var.ttl_hours) == var.ttl_hours
    error_message = "ttl_hours must be a positive integer."
  }
}

variable "bedrock_model_ids" {
  description = "Bedrock foundation model IDs the hosts may invoke, for the Studio assistant's stack-side credentials (e.g. anthropic.claude-sonnet-4-6). Empty (the default) gives the hosts no instance profile at all."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for id in var.bedrock_model_ids : can(regex("^[a-z0-9-]+\\.[a-z0-9.:-]+$", id)) && !strcontains(id, "*")])
    error_message = "bedrock_model_ids must be exact model IDs without wildcards."
  }
}

variable "intra_group_ssh" {
  description = "Allow SSH between hosts in this group, so one host can act as the controller (self-hosted runner) driving the others. Default false."
  type        = bool
  default     = false
}
