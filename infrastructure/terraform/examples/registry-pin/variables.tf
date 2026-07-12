variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "honua_image" {
  description = "Honua Server container image. Pin to an immutable release tag or digest."
  type        = string
}

variable "honua_admin_password" {
  description = "Admin API password for Honua."
  type        = string
  sensitive   = true
}

variable "honua_connection_encryption_master_key" {
  description = "Required connection-key decision. Set null only for a new deployment; existing deployments must set their current key before upgrading."
  type        = string
  sensitive   = true
  nullable    = true
}
