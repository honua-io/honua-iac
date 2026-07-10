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
  default     = "honuaaca"
}

variable "honua_admin_password" {
  description = "Admin password for Honua."
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
  description = "Container image to deploy. Pin to an immutable release tag or digest."
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

variable "min_replicas" {
  description = "Minimum replicas for Azure Container Apps. Values greater than 1 require the safe MultiNode inputs."
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Maximum replicas for Azure Container Apps. Values greater than 1 require the safe MultiNode inputs."
  type        = number
  default     = 1
}

variable "deployment_mode" {
  description = "Honua deployment mode. Use MultiNode only with Redis and shared Azure Blob file storage."
  type        = string
  default     = "SingleInstance"
}

variable "file_storage_provider" {
  description = "Honua file storage provider (Local or AzureBlob)."
  type        = string
  default     = "Local"
}

variable "file_storage_azure_blob_connection_string" {
  description = "Connection string for the existing Azure Storage account used by shared Honua file storage."
  type        = string
  sensitive   = true
  default     = ""
}

variable "file_storage_azure_blob_container_name" {
  description = "Existing Azure Blob container for shared Honua file storage."
  type        = string
  default     = ""
}

variable "file_storage_azure_blob_prefix" {
  description = "Optional blob prefix for Honua objects."
  type        = string
  default     = "honua"
}

variable "key_vault_default_action" {
  description = "Key Vault network ACL default action (Allow is useful for local integration tests)."
  type        = string
  default     = "Deny"
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

variable "tags" {
  description = "Additional tags for resources."
  type        = map(string)
  default     = {}
}
