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
  description = "Optional image for the staging deployment slot. Defaults to the primary image when empty."
  type        = string
  default     = ""
}

variable "container_port" {
  description = "Container port exposed by Honua Server."
  type        = number
  default     = 8080
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
  description = "Master key for Honua connection encryption (Security__ConnectionEncryption__MasterKey). Leave null to auto-generate an independent key for new deployments. Existing deployments must pin their current key before upgrading; see the module README."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.connection_encryption_master_key == null || length(var.connection_encryption_master_key) >= 32
    error_message = "connection_encryption_master_key must be at least 32 characters when set."
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

variable "storage_network_default_action" {
  description = "Storage account network default action."
  type        = string
  default     = "Deny"

  validation {
    condition     = contains(["Allow", "Deny"], var.storage_network_default_action)
    error_message = "storage_network_default_action must be either Allow or Deny."
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

variable "db_backup_retention_days" {
  description = "Backup retention period in days for PostgreSQL."
  type        = number
  default     = 14
}

# --- Azure OpenAI (AI studio / WorkflowGeneration) ------------------------
# Optional, off by default. The Azure mirror of enable_bedrock_ai: provisions
# (or references) an Azure OpenAI account + model deployment, grants the
# function's managed identity the "Cognitive Services OpenAI User" role, and
# injects the WorkflowGeneration__* env so the AI studio routes to Azure OpenAI
# via Entra managed-identity auth.

variable "enable_openai_ai" {
  description = "Provision/reference an Azure OpenAI account + deployment, grant the function's managed identity the Cognitive Services OpenAI User role, and route the server's AI studio (WorkflowGeneration) flows to Azure OpenAI. Off by default so existing deploys are unchanged."
  type        = bool
  default     = false
}

variable "openai_account_name" {
  description = "Name of an already-provisioned Azure OpenAI (Cognitive Services) account to reference instead of creating one (avoids account-quota friction). Leave empty to create a new account."
  type        = string
  default     = ""
}

variable "openai_account_rg" {
  description = "Resource group of the existing Azure OpenAI account (when openai_account_name is set). Defaults to the module's resource group when empty."
  type        = string
  default     = ""
}

variable "openai_endpoint" {
  description = "Optional explicit Azure OpenAI endpoint override (WorkflowGeneration provider Endpoint). When empty the created/referenced account's endpoint is used."
  type        = string
  default     = ""
}

variable "openai_deployment_name" {
  description = "Azure OpenAI model deployment name. Surfaced to the server as WorkflowGeneration provider Model (Azure OpenAI selects the model by deployment name)."
  type        = string
  default     = "honua-gpt-4o"
}

variable "openai_model" {
  description = "Azure OpenAI model id to deploy (the underlying OpenAI model name, e.g. gpt-4o). Used when creating a new deployment."
  type        = string
  default     = "gpt-4o"
}

variable "openai_model_version" {
  description = "Optional Azure OpenAI model version for the created deployment. Empty lets Azure pick the default for the model."
  type        = string
  default     = ""
}

variable "openai_deployment_sku" {
  description = "SKU name for the Azure OpenAI model deployment (e.g. Standard, GlobalStandard)."
  type        = string
  default     = "Standard"
}

variable "openai_deployment_capacity" {
  description = "Capacity (thousands of tokens per minute) for the Azure OpenAI model deployment."
  type        = number
  default     = 10
}

variable "openai_api_version" {
  description = "Azure OpenAI REST API version the server uses (WorkflowGeneration provider ApiVersion)."
  type        = string
  default     = "2024-10-21"
}

variable "openai_sku" {
  description = "SKU for the Azure OpenAI cognitive account."
  type        = string
  default     = "S0"
}

variable "openai_region" {
  description = "Azure region for the Azure OpenAI account. Defaults to the module location when empty."
  type        = string
  default     = ""
}

variable "openai_max_tokens" {
  description = "Max output tokens for Azure OpenAI generation (WorkflowGeneration provider MaxTokens)."
  type        = number
  default     = 4096

  validation {
    condition     = var.openai_max_tokens >= 256 && var.openai_max_tokens <= 128000
    error_message = "openai_max_tokens must be between 256 and 128000 (server-side WorkflowGeneration validation range)."
  }
}

variable "openai_timeout_seconds" {
  description = "Per-request timeout for Azure OpenAI generation (WorkflowGeneration provider TimeoutSeconds)."
  type        = number
  default     = 120

  validation {
    condition     = var.openai_timeout_seconds >= 5 && var.openai_timeout_seconds <= 300
    error_message = "openai_timeout_seconds must be between 5 and 300 (server-side WorkflowGeneration validation range)."
  }
}

# --- Pro license (Key Vault delivery) -------------------------------------
# Optional, off by default. The Azure mirror of the aws-serverless Secrets
# Manager Pro-license path: stores the signed envelope in a Key Vault secret and
# injects Licensing__LicenseContentSecretRef (server-side resolution) +
# Licensing__TrustedKeys__<keyId>. When off the server runs Community.

variable "enable_pro_license" {
  description = "Deliver a signed Pro license to the function app via Key Vault. Off by default; when off the server runs Community. Requires pro_license_content and pro_license_trusted_public_key when enabled."
  type        = bool
  default     = false
}

variable "pro_license_content" {
  description = "The signed Pro license envelope JSON (the relabeled, hyphen-free keyId envelope, e.g. keyId=honuademo2026q2). Stored in a dedicated Key Vault secret and referenced by Licensing__LicenseContentSecretRef. Required when enable_pro_license is true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "pro_license_key_id" {
  description = "The license signing keyId as relabeled in the envelope. Must be hyphen-free so it is a legal env var name segment (Licensing__TrustedKeys__<keyId>). Defaults to the demo key."
  type        = string
  default     = "honuademo2026q2"

  validation {
    condition     = can(regex("^[A-Za-z_][A-Za-z0-9_]*$", var.pro_license_key_id))
    error_message = "pro_license_key_id must be a valid environment-variable name segment (letters, digits, underscore; no hyphens)."
  }
}

variable "pro_license_trusted_public_key" {
  description = "The Ed25519 public key (base64url, with the base64url: prefix) that verifies the Pro license signature. Injected as Licensing__TrustedKeys__<pro_license_key_id>. Required when enable_pro_license is true."
  type        = string
  default     = ""
}
