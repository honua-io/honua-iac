variable "location" {
  description = "Azure region."
  type        = string
  default     = "eastus"
}

variable "environment" {
  description = "Environment name used in resource naming."
  type        = string
  default     = "it"
}

variable "name_prefix" {
  description = "Prefix used for resource names."
  type        = string
  default     = "honuafn"
}

variable "honua_admin_password" {
  description = "Admin API password for Honua."
  type        = string
  sensitive   = true
}

variable "db_admin_password" {
  description = "PostgreSQL admin password. Set for deterministic integration tests."
  type        = string
  sensitive   = true
  default     = null
}

variable "existing_db_fqdn" {
  description = "Optional existing PostgreSQL FQDN to reuse."
  type        = string
  default     = ""
}

variable "existing_db_connection_string" {
  description = "Optional existing PostgreSQL connection string to reuse."
  type        = string
  sensitive   = true
  default     = ""
}

variable "honua_image" {
  description = "Container image (Functions-compatible). Pin to an immutable release tag or digest. Prefer AOT builds; use JIT images only for debug fallback."
  type        = string
}

variable "registry_server" {
  description = "Optional registry server used to authenticate private image pulls."
  type        = string
  default     = ""
}

variable "registry_username" {
  description = "Optional registry username used to authenticate private image pulls."
  type        = string
  default     = ""
}

variable "registry_password" {
  description = "Optional registry password used to authenticate private image pulls."
  type        = string
  sensitive   = true
  default     = ""
}

variable "deployment_slot_enabled" {
  description = "Provision a staging deployment slot for slot-based rollout workflows."
  type        = bool
  default     = false
}

variable "deployment_slot_name" {
  description = "Name of the optional staging deployment slot."
  type        = string
  default     = "staging"
}

variable "deployment_slot_image" {
  description = "Optional container image for the staging slot. Defaults to honua_image when empty."
  type        = string
  default     = ""
}

variable "plan_sku_name" {
  description = "Function App plan SKU (EP* for Premium, Y1 for Consumption)."
  type        = string
  default     = "EP1"
}

variable "enable_postgis" {
  description = "Enable PostGIS and PostGIS Raster during apply."
  type        = bool
  default     = true
}

variable "redis_enabled" {
  description = "Provision Azure Cache for Redis."
  type        = bool
  default     = true
}

variable "redis_connection_string" {
  description = "Optional existing Redis connection string to reuse."
  type        = string
  sensitive   = true
  default     = ""
}

variable "redis_sku_name" {
  description = "Redis SKU for new cache creation."
  type        = string
  default     = "Standard"
}

variable "redis_family" {
  description = "Redis family for new cache creation."
  type        = string
  default     = "C"
}

variable "redis_capacity" {
  description = "Redis capacity for new cache creation."
  type        = number
  default     = 1
}

variable "key_vault_public_network_access_enabled" {
  description = "Whether the Functions Key Vault allows public network access."
  type        = bool
  default     = false
}

variable "storage_network_default_action" {
  description = "Storage account network default action."
  type        = string
  default     = "Deny"
}

variable "db_geo_redundant_backup_enabled" {
  description = "Enable geo-redundant backups for PostgreSQL."
  type        = bool
  default     = true
}

variable "db_backup_retention_days" {
  description = "Backup retention period in days for PostgreSQL."
  type        = number
  default     = 7
}

variable "db_firewall_start_ip" {
  description = "Optional PostgreSQL firewall start IP."
  type        = string
  default     = ""
}

variable "db_firewall_end_ip" {
  description = "Optional PostgreSQL firewall end IP."
  type        = string
  default     = ""
}

variable "skip_migrations" {
  description = "Skip database migrations on startup."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags for resources."
  type        = map(string)
  default     = {}
}
