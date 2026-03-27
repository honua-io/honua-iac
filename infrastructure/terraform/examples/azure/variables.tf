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

variable "install" {
  description = "Provider-neutral install questionnaire for artifact, database, network, and storage settings. Legacy provider-specific variables remain supported as fallbacks."
  type = object({
    artifact = optional(object({
      image = optional(string)
      registry = optional(object({
        server      = optional(string)
        auth_mode   = optional(string)
        resource_id = optional(string)
      }))
    }))
    database = optional(object({
      host                    = optional(string)
      compute_sku             = optional(string)
      storage_gb              = optional(number)
      storage_mb              = optional(number)
      public_access           = optional(bool)
      postgis_enabled         = optional(bool)
      readiness_max_attempts  = optional(number)
      readiness_sleep_seconds = optional(number)
    }))
    network = optional(object({
      id                   = optional(string)
      cidr                 = optional(string)
      public_subnet_ids    = optional(list(string))
      private_subnet_ids   = optional(list(string))
      public_ingress_cidrs = optional(list(string))
      http_ingress_cidrs   = optional(list(string))
      https_ingress_cidrs  = optional(list(string))
      firewall_start_ip    = optional(string)
      firewall_end_ip      = optional(string)
    }))
    storage = optional(object({
      enabled        = optional(bool)
      name           = optional(string)
      container_name = optional(string)
      prefix         = optional(string)
      force_destroy  = optional(bool)
    }))
  })
  default = {}
}

variable "honua_admin_password" {
  description = "Admin password for Honua."
  type        = string
  sensitive   = true
}

variable "connection_encryption_master_key" {
  description = "Optional override for Security__ConnectionEncryption__MasterKey. Leave null to auto-generate an independent secret."
  type        = string
  sensitive   = true
  default     = null
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
  default     = null
}

variable "container_port" {
  description = "Container port exposed by Honua Server."
  type        = number
  default     = 8080
}

variable "container_cpu" {
  description = "Container CPU cores."
  type        = number
  default     = 0.5
}

variable "container_memory" {
  description = "Container memory with Gi suffix."
  type        = string
  default     = "1Gi"
}

variable "registry_server" {
  description = "Container registry server (optional)."
  type        = string
  default     = ""
}

variable "registry_auth_mode" {
  description = "Registry auth mode for legacy provider-specific input (`auto`, `managed_identity`, or `username_password`)."
  type        = string
  default     = "auto"
}

variable "registry_resource_id" {
  description = "ACR resource id used for managed-identity image pulls."
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

variable "enable_postgis" {
  description = "Enable PostGIS and PostGIS Raster during apply."
  type        = bool
  default     = true
}

variable "postgis_readiness_max_attempts" {
  description = "Maximum readiness attempts before PostGIS enablement fails."
  type        = number
  default     = 30
}

variable "postgis_readiness_sleep_seconds" {
  description = "Seconds to wait between PostgreSQL readiness probes during PostGIS enablement."
  type        = number
  default     = 10
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

variable "db_sku_name" {
  description = "SKU name for Azure Database for PostgreSQL Flexible Server."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "db_storage_mb" {
  description = "Storage in MB for Azure Database for PostgreSQL Flexible Server."
  type        = number
  default     = 32768
}

variable "db_public_network_access" {
  description = "Enable public network access to PostgreSQL when the root install contract requires direct external reachability."
  type        = bool
  default     = false
}

variable "enable_ingress" {
  description = "Expose Azure Container Apps ingress publicly."
  type        = bool
  default     = false
}

variable "ingress_allowed_cidrs" {
  description = "CIDR ranges allowed to reach Azure Container Apps ingress."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.ingress_allowed_cidrs : can(cidrnetmask(cidr))])
    error_message = "ingress_allowed_cidrs must contain valid CIDR blocks."
  }
}

variable "db_backup_retention_days" {
  description = "Backup retention period in days for PostgreSQL."
  type        = number
  default     = 7
}

variable "min_replicas" {
  description = "Minimum replicas for Azure Container Apps."
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Maximum replicas for Azure Container Apps."
  type        = number
  default     = 3
}

variable "scaling_concurrent_requests" {
  description = "Concurrent HTTP requests per replica before scaling out."
  type        = string
  default     = "50"
}

variable "key_vault_default_action" {
  description = "Key Vault network ACL default action (Allow is useful for local integration tests)."
  type        = string
  default     = "Deny"
}

variable "key_vault_purge_protection_enabled" {
  description = "Enable purge protection on the Key Vault."
  type        = bool
  default     = true
}

variable "key_vault_soft_delete_retention_days" {
  description = "Number of days to retain soft-deleted Key Vault items."
  type        = number
  default     = 30
}

variable "key_vault_public_network_access_enabled" {
  description = "Allow public network access to Key Vault."
  type        = bool
  default     = false
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

variable "app_storage_enabled" {
  description = "Provision application Blob storage for validation and object-backed features."
  type        = bool
  default     = false
}

variable "app_storage_ip_rules" {
  description = "Optional IP CIDRs allowed to access the application storage account for validation probes."
  type        = list(string)
  default     = []
}

variable "app_storage_container_name" {
  description = "Blob container name for application storage probes."
  type        = string
  default     = "validation"
}
