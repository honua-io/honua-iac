variable "name_prefix" {
  description = "Name prefix for resources."
  type        = string
  default     = "honua"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "eastus"
}

variable "tags" {
  description = "Additional tags to apply to resources."
  type        = map(string)
  default     = {}
}

variable "image" {
  description = "Container image. Pin to an immutable release tag or digest; AOT builds are recommended for faster startup and lower memory."
  type        = string
}

variable "container_cpu" {
  description = "Container CPU cores."
  type        = number
  default     = 0.5

  validation {
    condition     = contains([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 4.0], var.container_cpu)
    error_message = "container_cpu must be one of: 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 4.0."
  }
}

variable "container_memory" {
  description = "Container memory with Gi suffix (for example 1Gi, 1.5Gi)."
  type        = string
  default     = "1Gi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]{1,2})?Gi$", var.container_memory))
    error_message = "container_memory must be a decimal value with Gi suffix, such as 1Gi or 1.5Gi."
  }
}

variable "container_port" {
  description = "Container port exposed by Honua Server."
  type        = number
  default     = 8080
}

variable "min_replicas" {
  description = "Minimum replicas for Container Apps. Values greater than 1 require deployment_mode=MultiNode with Redis and shared Azure Blob file storage."
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Maximum replicas for Container Apps. Values greater than 1 require deployment_mode=MultiNode with Redis and shared Azure Blob file storage."
  type        = number
  default     = 1
}

variable "deployment_mode" {
  description = "Honua deployment mode. MultiNode is required whenever Container Apps can run more than one replica."
  type        = string
  default     = "SingleInstance"

  validation {
    condition     = contains(["SingleInstance", "MultiNode"], var.deployment_mode)
    error_message = "deployment_mode must be SingleInstance or MultiNode."
  }
}

variable "file_storage_provider" {
  description = "Honua file storage provider. MultiNode Container Apps deployments require AzureBlob."
  type        = string
  default     = "Local"

  validation {
    condition     = contains(["Local", "AzureBlob"], var.file_storage_provider)
    error_message = "file_storage_provider must be Local or AzureBlob for the Azure ACA module."
  }
}

variable "file_storage_azure_blob_connection_string" {
  description = "Connection string for the existing Azure Storage account used by shared Honua file storage."
  type        = string
  sensitive   = true
  default     = ""
}

variable "file_storage_azure_blob_container_name" {
  description = "Existing Azure Blob container used for shared Honua file storage when file_storage_provider is AzureBlob."
  type        = string
  default     = ""

  validation {
    condition     = var.file_storage_azure_blob_container_name == "" || can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.file_storage_azure_blob_container_name))
    error_message = "file_storage_azure_blob_container_name must be empty or a valid 3-63 character Azure Blob container name."
  }
}

variable "file_storage_azure_blob_prefix" {
  description = "Optional blob prefix for Honua objects in the shared Azure Blob container."
  type        = string
  default     = "honua"
}

variable "admin_password" {
  description = "Admin API password for Honua (required in non-dev)."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.admin_password) >= 32
    error_message = "admin_password must be at least 32 characters."
  }
}

variable "connection_encryption_master_key" {
  description = "Master key for Honua connection encryption (Security__ConnectionEncryption__MasterKey). Explicitly set null to auto-generate an independent key for a new deployment. Existing deployments must supply their current key before upgrading; see the module README."
  type        = string
  sensitive   = true
  nullable    = true

  validation {
    condition     = var.connection_encryption_master_key == null || length(var.connection_encryption_master_key) >= 32
    error_message = "connection_encryption_master_key must be at least 32 characters when set."
  }
}

variable "db_admin_username" {
  description = "PostgreSQL admin username."
  type        = string
  default     = "honua"
}

variable "db_admin_password" {
  description = "PostgreSQL admin password. Leave null to auto-generate. Ignored when existing_db_connection_string is provided."
  type        = string
  sensitive   = true
  default     = null
}

variable "existing_db_fqdn" {
  description = "Optional existing PostgreSQL server FQDN to reuse instead of creating a new server."
  type        = string
  default     = ""
}

variable "existing_db_connection_string" {
  description = "Optional existing PostgreSQL connection string to reuse instead of creating a new server/database."
  type        = string
  default     = ""
  sensitive   = true
}

variable "db_name" {
  description = "PostgreSQL database name."
  type        = string
  default     = "honua"
}

variable "db_sku_name" {
  description = "SKU name for Azure Database for PostgreSQL Flexible Server."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "db_storage_mb" {
  description = "Storage in MB for PostgreSQL Flexible Server."
  type        = number
  default     = 32768
}

variable "db_version" {
  description = "PostgreSQL version."
  type        = string
  default     = "16"
}

variable "db_public_network_access" {
  description = "Enable public network access to the PostgreSQL server."
  type        = bool
  default     = false
}

variable "db_firewall_start_ip" {
  description = "Optional PostgreSQL firewall start IP. Set with db_firewall_end_ip to allow external validation access."
  type        = string
  default     = ""
}

variable "db_firewall_end_ip" {
  description = "Optional PostgreSQL firewall end IP. Set with db_firewall_start_ip to allow external validation access."
  type        = string
  default     = ""
}

variable "db_geo_redundant_backup_enabled" {
  description = "Enable geo-redundant backups for PostgreSQL Flexible Server."
  type        = bool
  default     = true
}

variable "enable_postgis" {
  description = "Attempt to enable PostGIS and PostGIS Raster via local-exec (requires psql + network access)."
  type        = bool
  default     = false
}

variable "additional_env" {
  description = "Additional environment variables for the container."
  type        = map(string)
  default     = {}

  validation {
    condition = length(setintersection(toset([
      for key in keys(var.additional_env) : lower(replace(key, ":", "__"))
      ]), toset([
      "deployment__mode",
      "filestorage__provider",
      "filestorage__azureblob__connectionstring",
      "filestorage__azureblob__containername",
      "filestorage__azureblob__blobprefix"
    ]))) == 0
    error_message = "Set deployment and file-storage settings through the typed module variables, not additional_env."
  }
}

variable "redis_connection_string" {
  description = "Redis connection string for multi-node mode. Leave empty to create Redis."
  type        = string
  default     = ""
  sensitive   = true
}

variable "redis_enabled" {
  description = "Provision Azure Cache for Redis."
  type        = bool
  default     = true
}

variable "redis_sku_name" {
  description = "Azure Cache for Redis SKU name."
  type        = string
  default     = "Standard"
}

variable "redis_family" {
  description = "Azure Cache for Redis family."
  type        = string
  default     = "C"
}

variable "redis_capacity" {
  description = "Azure Cache for Redis capacity."
  type        = number
  default     = 1
}

variable "redis_enable_non_ssl_port" {
  description = "Enable non-SSL port for Azure Cache for Redis."
  type        = bool
  default     = false
}

variable "redis_public_network_access_enabled" {
  description = "Enable public network access for Azure Cache for Redis."
  type        = bool
  default     = false
}

variable "redis_subnet_id" {
  description = "Subnet ID for Azure Cache for Redis (required for private access)."
  type        = string
  default     = ""
}

variable "registry_server" {
  description = "Container registry server (optional)."
  type        = string
  default     = ""
}

variable "registry_username" {
  description = "Container registry username (optional)."
  type        = string
  default     = ""
}

variable "registry_password" {
  description = "Container registry password (optional)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "key_vault_purge_protection_enabled" {
  description = "Enable purge protection on the Key Vault."
  type        = bool
  default     = true
}

variable "key_vault_public_network_access_enabled" {
  description = "Allow public network access to Key Vault."
  type        = bool
  default     = true
}

variable "key_vault_default_action" {
  description = "Default action for Key Vault network ACLs."
  type        = string
  default     = "Deny"
}

variable "key_vault_bypass" {
  description = "Key Vault network ACL bypass."
  type        = string
  default     = "AzureServices"
}

variable "key_vault_ip_rules" {
  description = "IP rules allowed to access Key Vault."
  type        = list(string)
  default     = []
}

variable "secret_expiration_days" {
  description = "Days until Key Vault secrets expire."
  type        = number
  default     = 365
}

variable "enable_ingress" {
  description = "Expose Container App via external ingress."
  type        = bool
  default     = true
}

variable "log_analytics_enabled" {
  description = "Enable Log Analytics workspace for Container Apps environment."
  type        = bool
  default     = true
}

variable "scaling_concurrent_requests" {
  description = "Number of concurrent HTTP requests per replica before scaling out."
  type        = string
  default     = "50"
}

variable "startup_probe_initial_delay_seconds" {
  description = "Initial delay before ACA startup probes begin, to leave room for cold boot and migrations."
  type        = number
  default     = 20
}

variable "startup_probe_failure_threshold" {
  description = "ACA startup probe failure threshold. Higher values prevent long first-start sequences from being killed prematurely."
  type        = number
  default     = 30
}

variable "db_backup_retention_days" {
  description = "Backup retention period in days for PostgreSQL."
  type        = number
  default     = 14
}

variable "key_vault_soft_delete_retention_days" {
  description = "Number of days to retain soft-deleted Key Vault items."
  type        = number
  default     = 30

  validation {
    condition     = var.key_vault_soft_delete_retention_days >= 7 && var.key_vault_soft_delete_retention_days <= 90
    error_message = "key_vault_soft_delete_retention_days must be between 7 and 90."
  }
}
