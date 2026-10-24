variable "region" {
  type    = string
  default = "us-east-1"
}

variable "account_id" {
  description = "Reviewed AWS account; provider refuses any other account."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Supply an exact AWS account ID."
  }
}

variable "attempt_id" {
  description = "Globally unique static attempt identity, or fixed physical slot allocation in installed mode. Never repurpose an old allocation after failure."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]{3,40}$", var.attempt_id))
    error_message = "Use 3–40 lowercase letters, digits or hyphens."
  }
}

variable "installed_slot" {
  description = "Optional installed runtime slot. Null preserves the static campaign protocol. These are installation identities and the original funding deadline, never per-turn inputs."
  type = object({
    runtime_id                     = string
    slot_id                        = string
    original_funding_expires_epoch = number
    max_execution_seconds          = number
  })
  default = null
  validation {
    condition = var.installed_slot == null ? true : (
      can(regex("^[A-Za-z0-9_-]{1,128}$", var.installed_slot.runtime_id)) &&
      can(regex("^[a-z0-9-]{3,40}$", var.installed_slot.slot_id)) &&
      var.installed_slot.original_funding_expires_epoch == floor(var.installed_slot.original_funding_expires_epoch) &&
      var.installed_slot.original_funding_expires_epoch > 0 &&
      var.installed_slot.max_execution_seconds == floor(var.installed_slot.max_execution_seconds) &&
      var.installed_slot.max_execution_seconds >= 60 && var.installed_slot.max_execution_seconds <= 6000
    )
    error_message = "An installed slot requires bounded runtime/slot identities, an integer original funding deadline, and a 60–6000 second execution ceiling."
  }
}

variable "candidate_digest" {
  type = string
  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.candidate_digest))
    error_message = "Bind the exact candidate component digest."
  }
}

variable "issued_epoch" {
  description = "Fixed reservation creation time, not a sliding Terraform timestamp."
  type        = number
  validation {
    condition     = var.issued_epoch == floor(var.issued_epoch) && var.issued_epoch > 0
    error_message = "Supply an integer Unix epoch."
  }
}

variable "lifetime_seconds" {
  type = number
  validation {
    condition     = var.lifetime_seconds == floor(var.lifetime_seconds) && var.lifetime_seconds >= 60 && var.lifetime_seconds <= 6000
    error_message = "Worker liability must be bounded to 60–6000 seconds."
  }
}

variable "cluster_arn" {
  description = "Existing isolated Fargate cluster provisioned by the campaign infrastructure."
  type        = string
}

variable "subnet_ids" {
  description = "Reviewed private subnets with egress to the queue, image and candidate endpoints."
  type        = set(string)
  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "At least one isolated subnet is required."
  }
}

variable "security_group_ids" {
  description = "Reviewed worker-only security groups; no ingress or controller access."
  type        = set(string)
  validation {
    condition     = length(var.security_group_ids) > 0
    error_message = "At least one reviewed security group is required."
  }
}

variable "image_uri" {
  description = "Worker image in this account/region's ECR, pinned by digest."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9/_-]+@sha256:[0-9a-f]{64}$", var.image_uri))
    error_message = "Supply a digest-pinned ECR worker image."
  }
}

variable "mcp_configuration" {
  description = "Optional existing Terraform-owned agent MCP configuration secret, pinned to an immutable version. Supply metadata only, never the secret value. Null supports terminal-only transport testing, not complete agent qualification."
  type = object({
    secret_arn  = string
    version_id  = string
    kms_key_arn = optional(string)
  })
  default = null
  validation {
    condition = var.mcp_configuration == null ? true : (
      can(regex("^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:honua-agent-[a-z0-9-]+-mcp-[A-Za-z0-9]{6}$", var.mcp_configuration.secret_arn)) &&
      can(regex("^[A-Za-z0-9-]{32,64}$", var.mcp_configuration.version_id)) &&
      (var.mcp_configuration.kms_key_arn == null ? true : can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/([a-f0-9-]{36}|mrk-[a-f0-9]{32})$", var.mcp_configuration.kms_key_arn)))
    )
    error_message = "Supply a complete agent MCP secret ARN, a 32-64 character immutable version ID and, when needed, an exact KMS key ARN (not an alias)."
  }
}

variable "claim_table_name" {
  description = "Existing durable controller table with string key candidateKey. No TTL or deletion of launch claims."
  type        = string
}

variable "cleanup_alarm_topic_arn" {
  description = "Existing monitored SNS topic with confirmed subscriptions; preflight must prove alert delivery."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$", var.cleanup_alarm_topic_arn))
    error_message = "Supply a standard SNS topic ARN for independently monitored cleanup alarms."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional existing permissions boundary for every worker, execution, lifecycle and cleanup role. The boundary must allow the module's queue, task, claim and cleanup operations."
  type        = string
  default     = null
  validation {
    condition     = var.permissions_boundary_arn == null ? true : can(regex("^arn:aws:iam::[0-9]{12}:policy/[^*?]+$", var.permissions_boundary_arn))
    error_message = "Supply an exact IAM managed policy ARN in the reviewed worker account."
  }
}
