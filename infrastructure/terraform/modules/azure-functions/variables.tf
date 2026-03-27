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
  description = "Container image. Pin to an immutable release tag or digest. Prefer AOT builds; use JIT images only for debug fallback."
  type        = string

  validation {
    condition = (
      trimspace(var.image) != "" &&
      (
        can(regex(".+@sha256:[0-9A-Fa-f]{64}$", trimspace(var.image))) ||
        can(regex(".+:[^/:@]+$", trimspace(var.image)))
      )
    )
    error_message = "image must be a non-empty container reference with either a tag or sha256 digest."
  }
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

  validation {
    condition     = trimspace(var.deployment_slot_name) != "" && can(regex("^[A-Za-z0-9-]{1,60}$", var.deployment_slot_name))
    error_message = "deployment_slot_name must be 1-60 characters of letters, numbers, or hyphens."
  }
}

variable "deployment_slot_image" {
  description = "Optional image for the staging deployment slot. Defaults to the primary image when empty."
  type        = string
  default     = ""
}

variable "container_port" {
  description = "Container port exposed by Honua Server."
  type        = number
  default     = 8080

  validation {
    condition     = var.container_port >= 1 && var.container_port <= 65535
    error_message = "container_port must be between 1 and 65535."
  }
}

variable "plan_sku_name" {
  description = "Function App plan SKU (EP* for Premium, Y1 for Consumption)."
  type        = string
  default     = "EP1"
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
  description = "Optional override for Security__ConnectionEncryption__MasterKey. Leave null to auto-generate an independent secret."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.connection_encryption_master_key == null ? true : length(var.connection_encryption_master_key) >= 32
    error_message = "connection_encryption_master_key must be null or at least 32 characters."
  }
}

variable "skip_migrations" {
  description = "Skip database migrations on startup."
  type        = bool
  default     = true
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

variable "existing_db_admin_password" {
  description = "Admin password usable when enabling PostGIS on an existing PostgreSQL server."
  type        = string
  sensitive   = true
  default     = ""
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

  validation {
    condition     = var.db_storage_mb >= 32768
    error_message = "db_storage_mb must be at least 32768 MB."
  }
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
  description = "Enable PostGIS and PostGIS Raster via Terraform's `postgresql_extension` resources. When reusing a database, also provide `existing_db_admin_password` so Terraform can authenticate."
  type        = bool
  default     = true
}

variable "postgis_readiness_max_attempts" {
  description = "Maximum readiness attempts before PostGIS enablement fails."
  type        = number
  default     = 30

  validation {
    condition     = var.postgis_readiness_max_attempts >= 1
    error_message = "postgis_readiness_max_attempts must be at least 1."
  }
}

variable "postgis_readiness_sleep_seconds" {
  description = "Seconds to wait between PostgreSQL readiness probes during PostGIS enablement."
  type        = number
  default     = 10

  validation {
    condition     = var.postgis_readiness_sleep_seconds >= 1
    error_message = "postgis_readiness_sleep_seconds must be at least 1."
  }
}

variable "additional_env" {
  description = "Additional environment variables for the Function App."
  type        = map(string)
  default     = {}
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
  description = "Container registry server (optional). When set without explicit credentials, the module defaults to managed-identity image pulls."
  type        = string
  default     = ""
}

variable "registry_auth_mode" {
  description = "Container registry auth mode. Use managed_identity for ACR pull via the Function App user-assigned identity, username_password for a legacy pull secret, or auto to infer from the supplied inputs."
  type        = string
  default     = "auto"

  validation {
    condition     = contains(["auto", "managed_identity", "username_password"], lower(trimspace(var.registry_auth_mode)))
    error_message = "registry_auth_mode must be one of: auto, managed_identity, username_password."
  }
}

variable "registry_resource_id" {
  description = "Optional Azure Container Registry resource ID. When set with managed_identity auth, the module grants AcrPull to the runtime identity."
  type        = string
  default     = ""
}

variable "registry_username" {
  description = "Container registry username (optional fallback for username_password auth)."
  type        = string
  default     = ""
}

variable "registry_password" {
  description = "Container registry password (optional fallback for username_password auth)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "app_insights_enabled" {
  description = "Enable Application Insights for the Function App."
  type        = bool
  default     = true
}

variable "functions_extension_version" {
  description = "Azure Functions runtime version."
  type        = string
  default     = "~4"
}

variable "functions_worker_runtime" {
  description = "Functions worker runtime (custom for custom handlers)."
  type        = string
  default     = "custom"
}

variable "storage_account_tier" {
  description = "Storage account tier."
  type        = string
  default     = "Standard"
}

variable "storage_account_replication_type" {
  description = "Storage account replication type."
  type        = string
  default     = "LRS"
}

variable "app_storage_enabled" {
  description = "Provision a dedicated Blob storage account and container for application storage smoke tests."
  type        = bool
  default     = false
}

variable "app_storage_container_name" {
  description = "Blob container name used for application storage and validation probes."
  type        = string
  default     = "validation"

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])?$", var.app_storage_container_name))
    error_message = "app_storage_container_name must be 3-63 characters of lowercase letters, numbers, or hyphens."
  }
}

variable "app_storage_ip_rules" {
  description = "Optional IP CIDRs allowed to access the application storage account for validation probes."
  type        = list(string)
  default     = []
}

variable "app_storage_default_action" {
  description = "Default network action for the application storage account."
  type        = string
  default     = "Deny"

  validation {
    condition     = contains(["Allow", "Deny"], var.app_storage_default_action)
    error_message = "app_storage_default_action must be either Allow or Deny."
  }
}

variable "public_network_access_enabled" {
  description = "Whether the Function App is reachable from public networks."
  type        = bool
  default     = false
}

variable "allowed_ip_cidrs" {
  description = "CIDR ranges allowed to reach the Function App when public network access is enabled."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.allowed_ip_cidrs : can(cidrnetmask(cidr))])
    error_message = "allowed_ip_cidrs must contain valid CIDR blocks."
  }
}

variable "scm_allowed_ip_cidrs" {
  description = "Optional CIDR ranges allowed to reach the Kudu/SCM endpoint. Defaults to allowed_ip_cidrs when empty."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.scm_allowed_ip_cidrs : can(cidrnetmask(cidr))])
    error_message = "scm_allowed_ip_cidrs must contain valid CIDR blocks."
  }
}

variable "serve_admin_ui" {
  description = "Enable the Honua admin UI."
  type        = bool
  default     = false
}

variable "key_vault_public_network_access_enabled" {
  description = "Whether Key Vault is accessible from public networks."
  type        = bool
  default     = false
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

  validation {
    condition     = var.key_vault_soft_delete_retention_days >= 7 && var.key_vault_soft_delete_retention_days <= 90
    error_message = "key_vault_soft_delete_retention_days must be between 7 and 90."
  }
}

variable "key_vault_default_action" {
  description = "Key Vault network ACL default action."
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

variable "key_vault_diagnostics_enabled" {
  description = "Enable AuditEvent diagnostics for Key Vault."
  type        = bool
  default     = true
}

variable "key_vault_diagnostics_workspace_id" {
  description = "Optional Log Analytics workspace resource ID for Key Vault diagnostics. Defaults to the module Log Analytics workspace when Application Insights is enabled."
  type        = string
  default     = ""

  validation {
    condition     = trimspace(var.key_vault_diagnostics_workspace_id) == "" || can(regex("^/subscriptions/", trimspace(var.key_vault_diagnostics_workspace_id)))
    error_message = "key_vault_diagnostics_workspace_id must be empty or a valid Azure resource ID starting with /subscriptions/."
  }
}

variable "secret_expiration_days" {
  description = "Days until Key Vault secrets expire."
  type        = number
  default     = 365
}

variable "db_backup_retention_days" {
  description = "Backup retention period in days for PostgreSQL."
  type        = number
  default     = 14
}
