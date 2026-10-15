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
  description = "Globally unique attempt identity; never reuse after failure."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]{3,40}$", var.attempt_id))
    error_message = "Use 3–40 lowercase letters, digits or hyphens."
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

variable "claim_table_name" {
  description = "Existing durable controller table with string key candidateKey. No TTL or deletion of launch claims."
  type        = string
}
