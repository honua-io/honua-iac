data "azurerm_client_config" "current" {}

resource "random_string" "storage_suffix" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

resource "random_string" "app_storage_suffix" {
  count   = var.app_storage_enabled ? 1 : 0
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

locals {
  name = "${var.name_prefix}-${var.environment}"
  tags = merge({
    Project     = "honua-server"
    Environment = var.environment
    ManagedBy   = "terraform"
  }, var.tags)
  storage_account_name       = substr(replace(lower("${var.name_prefix}${var.environment}${random_string.storage_suffix.result}"), "-", ""), 0, 24)
  app_storage_account_name   = var.app_storage_enabled ? substr(replace(lower("${var.name_prefix}${var.environment}app${random_string.app_storage_suffix[0].result}"), "-", ""), 0, 24) : null
  db_use_existing            = var.existing_db_connection_string != ""
  registry_server_normalized = trimspace(var.registry_server)
  registry_auth_mode_resolved = local.registry_server_normalized == "" ? "none" : (
    lower(trimspace(var.registry_auth_mode)) == "auto"
    ? (
      trimspace(var.registry_username) != "" && trimspace(var.registry_password) != ""
      ? "username_password"
      : "managed_identity"
    )
    : lower(trimspace(var.registry_auth_mode))
  )
}

check "existing_db_inputs" {
  assert {
    condition     = (var.existing_db_fqdn == "" && var.existing_db_connection_string == "") || (var.existing_db_fqdn != "" && var.existing_db_connection_string != "")
    error_message = "existing_db_fqdn and existing_db_connection_string must be set together."
  }
}

check "existing_postgis_credentials" {
  assert {
    condition     = !(local.db_use_existing && var.enable_postgis) || var.existing_db_admin_password != "" || var.db_admin_password != null
    error_message = "Provide existing_db_admin_password or db_admin_password when enabling PostGIS on an existing database."
  }
}

check "db_public_access_requires_firewall_rule" {
  assert {
    condition     = local.db_use_existing || !var.db_public_network_access || (trimspace(var.db_firewall_start_ip) != "" && trimspace(var.db_firewall_end_ip) != "")
    error_message = "Set db_firewall_start_ip and db_firewall_end_ip when db_public_network_access is true."
  }
}

check "redis_reuse_is_exclusive" {
  assert {
    condition     = !(var.redis_enabled && trimspace(var.redis_connection_string) != "")
    error_message = "Set either redis_enabled = true to provision Redis or redis_connection_string to reuse an existing Redis instance, not both."
  }
}

check "deployment_slot_name_required" {
  assert {
    condition     = !var.deployment_slot_enabled || trimspace(var.deployment_slot_name) != ""
    error_message = "deployment_slot_name must not be empty when deployment_slot_enabled is true."
  }
}

check "public_access_requires_ip_restriction" {
  assert {
    condition     = !var.public_network_access_enabled || length(var.allowed_ip_cidrs) > 0
    error_message = "Set allowed_ip_cidrs when public_network_access_enabled is true."
  }
}

check "key_vault_diagnostics_requires_workspace" {
  assert {
    condition     = !var.key_vault_diagnostics_enabled || trimspace(var.key_vault_diagnostics_workspace_id) != "" || var.app_insights_enabled
    error_message = "Enable app_insights_enabled or set key_vault_diagnostics_workspace_id when key_vault_diagnostics_enabled is true."
  }
}

resource "azurerm_resource_group" "this" {
  name     = "${local.name}-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_user_assigned_identity" "function" {
  name                = "${local.name}-func-identity"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "function_registry_pull" {
  count = local.registry_auth_mode_resolved == "managed_identity" && trimspace(var.registry_resource_id) != "" ? 1 : 0

  scope                = var.registry_resource_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.function.principal_id
}

#checkov:skip=CKV_AZURE_33: Queue logging is not required for every deployment and can be layered on by operators.
#checkov:skip=CKV_AZURE_59: Public access can be enabled for validation environments; network rules already default-deny.
#checkov:skip=CKV_AZURE_190: Blob public access is controlled separately; this module keeps network rules restrictive.
#checkov:skip=CKV_AZURE_206: Replication strategy remains configurable so lower-cost environments can use LRS.
#checkov:skip=CKV2_AZURE_1: Customer-managed keys are optional and managed outside this module.
#checkov:skip=CKV2_AZURE_33: Private endpoints are configured outside this module.
#checkov:skip=CKV2_AZURE_40: Shared key authorization remains available for Functions runtime/storage compatibility.
#checkov:skip=CKV2_AZURE_41: SAS expiration policies are managed outside this module.
#checkov:skip=CKV2_AZURE_47: Blob anonymous access is disabled operationally outside this module.
resource "azurerm_storage_account" "this" {
  #checkov:skip=CKV_AZURE_33: Queue logging is not required for every deployment and can be layered on by operators.
  #checkov:skip=CKV_AZURE_59: Public access can be enabled for validation environments; network rules already default-deny.
  #checkov:skip=CKV_AZURE_190: Blob public access is controlled separately; this module keeps network rules restrictive.
  #checkov:skip=CKV_AZURE_206: Replication strategy remains configurable so lower-cost environments can use LRS.
  #checkov:skip=CKV2_AZURE_1: Customer-managed keys are optional and managed outside this module.
  #checkov:skip=CKV2_AZURE_33: Private endpoints are configured outside this module.
  #checkov:skip=CKV2_AZURE_40: Shared key authorization remains available for Functions runtime/storage compatibility.
  #checkov:skip=CKV2_AZURE_41: SAS expiration policies are managed outside this module.
  #checkov:skip=CKV2_AZURE_47: Blob anonymous access is disabled operationally outside this module.
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = var.storage_account_tier
  account_replication_type = var.storage_account_replication_type
  min_tls_version          = "TLS1_2"
  tags                     = local.tags

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }
}

#checkov:skip=CKV2_AZURE_1: Customer-managed keys are optional and managed outside this module.
#checkov:skip=CKV2_AZURE_33: Private endpoints are configured outside this module.
#checkov:skip=CKV2_AZURE_40: Shared key authorization is retained so validation tooling can exercise blob storage safely.
#checkov:skip=CKV2_AZURE_41: SAS expiration policies are managed outside this module.
#checkov:skip=CKV_AZURE_59: Public access is constrained by deny-by-default network rules and optional private endpoints are managed outside this module.
#checkov:skip=CKV_AZURE_206: Replication strategy is environment-specific for optional application object storage.
#checkov:skip=CKV_AZURE_33: Queue logging is not configured because this storage account is used for blob containers, not queue workloads.
resource "azurerm_storage_account" "app_storage" {
  #checkov:skip=CKV2_AZURE_1: Customer-managed keys are optional and managed outside this module.
  #checkov:skip=CKV2_AZURE_33: Private endpoints are configured outside this module.
  #checkov:skip=CKV2_AZURE_40: Shared key authorization is retained so validation tooling can exercise blob storage safely.
  #checkov:skip=CKV2_AZURE_41: SAS expiration policies are managed outside this module.
  #checkov:skip=CKV_AZURE_59: Public access is constrained by deny-by-default network rules and optional private endpoints are managed outside this module.
  #checkov:skip=CKV_AZURE_206: Replication strategy is environment-specific for optional application object storage.
  #checkov:skip=CKV_AZURE_33: Queue logging is not configured because this storage account is used for blob containers, not queue workloads.
  count = var.app_storage_enabled ? 1 : 0

  name                            = local.app_storage_account_name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = var.storage_account_tier
  account_replication_type        = var.storage_account_replication_type
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  tags                            = local.tags

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }
}

#checkov:skip=CKV2_AZURE_21: Blob service logging is configured at the storage account level, not on the container resource itself.
resource "azurerm_storage_container" "app_storage" {
  #checkov:skip=CKV2_AZURE_21: Blob service logging is configured at the storage account level, not on the container resource itself.
  count = var.app_storage_enabled ? 1 : 0

  name                  = var.app_storage_container_name
  storage_account_id    = azurerm_storage_account.app_storage[0].id
  container_access_type = "private"
}

#checkov:skip=CKV_AZURE_212: Minimum-instance strategy depends on the selected plan SKU and environment.
#checkov:skip=CKV_AZURE_225: Zone redundancy depends on the selected plan SKU and environment.
resource "azurerm_service_plan" "this" {
  #checkov:skip=CKV_AZURE_212: Minimum-instance strategy depends on the selected plan SKU and environment.
  #checkov:skip=CKV_AZURE_225: Zone redundancy depends on the selected plan SKU and environment.
  name                = "${local.name}-plan"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  os_type             = "Linux"
  sku_name            = var.plan_sku_name
  tags                = local.tags
}

resource "random_password" "db" {
  count            = var.db_admin_password == null && !local.db_use_existing ? 1 : 0
  length           = 32
  special          = true
  override_special = "#%*()-_=+[]{}:?."

  lifecycle {
    ignore_changes = [length, special, override_special]
  }
}

resource "random_password" "connection_encryption_master_key" {
  count            = var.connection_encryption_master_key == null ? 1 : 0
  length           = 32
  special          = true
  override_special = "#%*()-_=+[]{}:?."

  lifecycle {
    ignore_changes = [length, special, override_special]
  }
}

resource "time_static" "secret_baseline" {}

locals {
  db_password                      = var.db_admin_password != null ? var.db_admin_password : (local.db_use_existing ? var.existing_db_admin_password : random_password.db[0].result)
  db_server_fqdn                   = local.db_use_existing ? var.existing_db_fqdn : azurerm_postgresql_flexible_server.this[0].fqdn
  db_connection_string             = local.db_use_existing ? var.existing_db_connection_string : "Host=${azurerm_postgresql_flexible_server.this[0].fqdn};Port=5432;Database=${var.db_name};Username=${var.db_admin_username};Password=${local.db_password};SSL Mode=Require;Trust Server Certificate=false"
  connection_encryption_master_key = var.connection_encryption_master_key != null ? var.connection_encryption_master_key : random_password.connection_encryption_master_key[0].result
  redis_enabled                    = var.redis_enabled || var.redis_connection_string != ""
  redis_create                     = var.redis_enabled && var.redis_connection_string == ""
  redis_connection                 = var.redis_connection_string != "" ? var.redis_connection_string : (local.redis_create ? azurerm_redis_cache.this[0].primary_connection_string : "")
  secret_expiration_date           = timeadd(time_static.secret_baseline.rfc3339, format("%dh", var.secret_expiration_days * 24))
  key_vault_diagnostics_workspace_id = trimspace(var.key_vault_diagnostics_workspace_id) != "" ? trimspace(var.key_vault_diagnostics_workspace_id) : (
    var.app_insights_enabled ? azurerm_log_analytics_workspace.this[0].id : null
  )
}

provider "postgresql" {
  alias           = "honua"
  host            = local.db_server_fqdn
  port            = 5432
  database        = var.db_name
  username        = var.db_admin_username
  password        = local.db_password
  sslmode         = "require"
  connect_timeout = 10
}

#checkov:skip=CKV2_AZURE_57: Private endpoints are configured outside this module.
resource "azurerm_postgresql_flexible_server" "this" {
  #checkov:skip=CKV2_AZURE_57: Private endpoints are configured outside this module.
  count                  = local.db_use_existing ? 0 : 1
  name                   = "${local.name}-pg"
  resource_group_name    = azurerm_resource_group.this.name
  location               = azurerm_resource_group.this.location
  version                = var.db_version
  administrator_login    = var.db_admin_username
  administrator_password = local.db_password
  storage_mb             = var.db_storage_mb
  sku_name               = var.db_sku_name

  public_network_access_enabled = var.db_public_network_access
  geo_redundant_backup_enabled  = var.db_geo_redundant_backup_enabled
  backup_retention_days         = var.db_backup_retention_days

  tags = local.tags
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "validation" {
  count = !local.db_use_existing && var.db_public_network_access && var.db_firewall_start_ip != "" && var.db_firewall_end_ip != "" ? 1 : 0

  name             = "validation-access"
  server_id        = azurerm_postgresql_flexible_server.this[0].id
  start_ip_address = var.db_firewall_start_ip
  end_ip_address   = var.db_firewall_end_ip
}

resource "azurerm_postgresql_flexible_server_database" "this" {
  count     = local.db_use_existing ? 0 : 1
  name      = var.db_name
  server_id = azurerm_postgresql_flexible_server.this[0].id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_configuration" "require_secure_transport" {
  count     = local.db_use_existing ? 0 : 1
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.this[0].id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "postgis" {
  count     = !local.db_use_existing && var.enable_postgis ? 1 : 0
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.this[0].id
  value     = "POSTGIS,POSTGIS_RASTER"
}

resource "azurerm_redis_cache" "this" {
  count                         = local.redis_create ? 1 : 0
  name                          = "${local.name}-redis"
  location                      = azurerm_resource_group.this.location
  resource_group_name           = azurerm_resource_group.this.name
  capacity                      = var.redis_capacity
  family                        = var.redis_family
  sku_name                      = var.redis_sku_name
  non_ssl_port_enabled          = var.redis_enable_non_ssl_port
  public_network_access_enabled = var.redis_public_network_access_enabled
  subnet_id                     = var.redis_subnet_id != "" ? var.redis_subnet_id : null
  minimum_tls_version           = "1.2"
  tags                          = local.tags
}

resource "azurerm_log_analytics_workspace" "this" {
  count               = var.app_insights_enabled ? 1 : 0
  name                = "${local.name}-logs"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_application_insights" "this" {
  count               = var.app_insights_enabled ? 1 : 0
  name                = "${local.name}-appinsights"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.this[0].id
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  count                      = var.key_vault_diagnostics_enabled && (trimspace(var.key_vault_diagnostics_workspace_id) != "" || var.app_insights_enabled) ? 1 : 0
  name                       = "${local.name}-kv-diagnostics"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = local.key_vault_diagnostics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }
}

#checkov:skip=CKV_AZURE_109: Key Vault firewall rules are configured outside this module.
#checkov:skip=CKV_AZURE_189: Private endpoints are configured outside this module.
#checkov:skip=CKV2_AZURE_32: Private endpoints are configured outside this module.
resource "azurerm_key_vault" "this" {
  #checkov:skip=CKV_AZURE_109: Key Vault firewall rules are configured outside this module.
  #checkov:skip=CKV_AZURE_189: Private endpoints are configured outside this module.
  #checkov:skip=CKV2_AZURE_32: Private endpoints are configured outside this module.
  name                          = "${local.name}-kv"
  location                      = azurerm_resource_group.this.location
  resource_group_name           = azurerm_resource_group.this.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  soft_delete_retention_days    = var.key_vault_soft_delete_retention_days
  purge_protection_enabled      = var.key_vault_purge_protection_enabled
  public_network_access_enabled = var.key_vault_public_network_access_enabled

  network_acls {
    default_action = var.key_vault_default_action
    bypass         = var.key_vault_bypass
    ip_rules       = var.key_vault_ip_rules
  }

  tags = local.tags
}

resource "azurerm_key_vault_access_policy" "terraform" {
  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = ["Get", "Set", "Delete", "Purge", "List"]
}

#checkov:skip=CKV_AZURE_41: Secret expiration is managed by the deployment environment.
#checkov:skip=CKV_AZURE_114: Secret content type is not required for runtime resolution.
resource "azurerm_key_vault_secret" "connection_string" {
  #checkov:skip=CKV_AZURE_41: Secret expiration is managed by the deployment environment.
  #checkov:skip=CKV_AZURE_114: Secret content type is not required for runtime resolution.
  name            = "connection-string"
  value           = local.db_connection_string
  content_type    = "connection-string"
  expiration_date = local.secret_expiration_date
  key_vault_id    = azurerm_key_vault.this.id

  depends_on = [azurerm_key_vault_access_policy.terraform]
}

#checkov:skip=CKV_AZURE_41: Secret expiration is managed by the deployment environment.
#checkov:skip=CKV_AZURE_114: Secret content type is not required for runtime resolution.
resource "azurerm_key_vault_secret" "admin_password" {
  #checkov:skip=CKV_AZURE_41: Secret expiration is managed by the deployment environment.
  #checkov:skip=CKV_AZURE_114: Secret content type is not required for runtime resolution.
  name            = "admin-password"
  value           = var.admin_password
  content_type    = "password"
  expiration_date = local.secret_expiration_date
  key_vault_id    = azurerm_key_vault.this.id

  depends_on = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "connection_encryption_master_key" {
  name            = "connection-encryption-master-key"
  value           = local.connection_encryption_master_key
  content_type    = "password"
  expiration_date = local.secret_expiration_date
  key_vault_id    = azurerm_key_vault.this.id

  depends_on = [azurerm_key_vault_access_policy.terraform]
}

#checkov:skip=CKV_AZURE_41: Secret expiration is managed by the deployment environment.
#checkov:skip=CKV_AZURE_114: Secret content type is not required for runtime resolution.
resource "azurerm_key_vault_secret" "redis_connection" {
  #checkov:skip=CKV_AZURE_41: Secret expiration is managed by the deployment environment.
  #checkov:skip=CKV_AZURE_114: Secret content type is not required for runtime resolution.
  count           = local.redis_enabled ? 1 : 0
  name            = "redis-connection"
  value           = local.redis_connection
  content_type    = "connection-string"
  expiration_date = local.secret_expiration_date
  key_vault_id    = azurerm_key_vault.this.id

  depends_on = [azurerm_key_vault_access_policy.terraform]
}

locals {
  base_app_settings = {
    FUNCTIONS_WORKER_RUNTIME            = var.functions_worker_runtime
    FUNCTIONS_CUSTOMHANDLER_PORT        = tostring(var.container_port)
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
    # Use the Functions host ping endpoint for App Service warmup so the site
    # can finish custom-handler startup before Honua's own readiness probes run.
    WEBSITE_WARMUP_PATH                       = "/admin/host/ping"
    WEBSITE_WARMUP_STATUSES                   = "200"
    AzureWebJobsStorage                       = azurerm_storage_account.this.primary_connection_string
    ConnectionStrings__DefaultConnection      = local.db_connection_string
    HONUA_ADMIN_PASSWORD                      = var.admin_password
    Security__ConnectionEncryption__MasterKey = local.connection_encryption_master_key
    HONUA_SERVE_ADMIN_UI                      = var.serve_admin_ui ? "true" : "false"
    HONUA_ADMIN_UI                            = var.serve_admin_ui ? "true" : "false"
    HONUA_OBSERVABILITY                       = "true"
    HONUA_SKIP_MIGRATIONS                     = var.skip_migrations ? "true" : "false"
  }
  redis_secret_settings = local.redis_connection != "" ? {
    ConnectionStrings__redis = local.redis_connection
  } : {}
  image_parts         = split("/", var.image)
  image_registry      = local.image_parts[0]
  image_path_and_tag  = join("/", slice(local.image_parts, 1, length(local.image_parts)))
  image_path_parts    = split(":", local.image_path_and_tag)
  image_name          = local.image_path_parts[0]
  image_tag           = length(local.image_path_parts) > 1 ? local.image_path_parts[1] : "latest"
  image_registry_url  = local.registry_server_normalized != "" ? (startswith(local.registry_server_normalized, "http") ? local.registry_server_normalized : "https://${local.registry_server_normalized}") : "https://${local.image_registry}"
  image_registry_user = local.registry_auth_mode_resolved == "username_password" && var.registry_username != "" ? var.registry_username : null
  image_registry_pass = local.registry_auth_mode_resolved == "username_password" && var.registry_password != "" ? var.registry_password : null

  slot_image               = var.deployment_slot_image != "" ? var.deployment_slot_image : var.image
  slot_image_parts         = split("/", local.slot_image)
  slot_image_registry      = local.slot_image_parts[0]
  slot_image_path_and_tag  = join("/", slice(local.slot_image_parts, 1, length(local.slot_image_parts)))
  slot_image_path_parts    = split(":", local.slot_image_path_and_tag)
  slot_image_name          = local.slot_image_path_parts[0]
  slot_image_tag           = length(local.slot_image_path_parts) > 1 ? local.slot_image_path_parts[1] : "latest"
  slot_image_registry_url  = local.registry_server_normalized != "" ? (startswith(local.registry_server_normalized, "http") ? local.registry_server_normalized : "https://${local.registry_server_normalized}") : "https://${local.slot_image_registry}"
  slot_image_registry_user = local.registry_auth_mode_resolved == "username_password" && var.registry_username != "" ? var.registry_username : null
  slot_image_registry_pass = local.registry_auth_mode_resolved == "username_password" && var.registry_password != "" ? var.registry_password : null
  registry_settings = local.registry_auth_mode_resolved == "username_password" ? {
    DOCKER_REGISTRY_SERVER_URL      = local.image_registry_url
    DOCKER_REGISTRY_SERVER_USERNAME = var.registry_username
    DOCKER_REGISTRY_SERVER_PASSWORD = var.registry_password
  } : {}
  app_insights_settings = var.app_insights_enabled ? {
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.this[0].connection_string
    APPINSIGHTS_INSTRUMENTATIONKEY        = azurerm_application_insights.this[0].instrumentation_key
  } : {}
  app_settings = merge(local.base_app_settings, local.redis_secret_settings, local.registry_settings, local.app_insights_settings, var.additional_env)
}

#checkov:skip=CKV_AZURE_221: Public access remains configurable so validation and MVP environments can be reached without private networking.
resource "azurerm_linux_function_app" "this" {
  #checkov:skip=CKV_AZURE_221: Public access remains configurable so validation and MVP environments can be reached without private networking.
  name                = "${local.name}-functions"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  service_plan_id     = azurerm_service_plan.this.id

  storage_account_name          = azurerm_storage_account.this.name
  storage_uses_managed_identity = true

  https_only                    = true
  functions_extension_version   = var.functions_extension_version
  public_network_access_enabled = var.public_network_access_enabled

  app_settings = local.app_settings

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.function.id]
  }

  site_config {
    always_on                                     = var.plan_sku_name != "Y1"
    container_registry_managed_identity_client_id = local.registry_auth_mode_resolved == "managed_identity" && local.registry_server_normalized != "" ? azurerm_user_assigned_identity.function.client_id : null
    container_registry_use_managed_identity       = local.registry_auth_mode_resolved == "managed_identity" && local.registry_server_normalized != ""
    health_check_path                             = "/healthz/ready"
    health_check_eviction_time_in_min             = 2
    ip_restriction_default_action                 = "Deny"
    scm_ip_restriction_default_action             = "Deny"
    scm_use_main_ip_restriction                   = length(var.scm_allowed_ip_cidrs) == 0

    dynamic "ip_restriction" {
      for_each = { for idx, cidr in var.allowed_ip_cidrs : idx => cidr }

      content {
        name       = "allow-${ip_restriction.key}"
        priority   = 100 + tonumber(ip_restriction.key)
        action     = "Allow"
        ip_address = ip_restriction.value
      }
    }

    dynamic "scm_ip_restriction" {
      for_each = { for idx, cidr in var.scm_allowed_ip_cidrs : idx => cidr }

      content {
        name       = "allow-${scm_ip_restriction.key}"
        priority   = 100 + tonumber(scm_ip_restriction.key)
        action     = "Allow"
        ip_address = scm_ip_restriction.value
      }
    }

    application_stack {
      docker {
        registry_url      = local.image_registry_url
        image_name        = local.image_name
        image_tag         = local.image_tag
        registry_username = local.image_registry_user
        registry_password = local.image_registry_pass
      }
    }
  }

  tags = local.tags

  # Azure injects and normalizes several Function App settings after create
  # (for example storage/account telemetry settings), which otherwise causes
  # perpetual drift during idempotency checks.
  lifecycle {
    ignore_changes = [
      app_settings["APPINSIGHTS_INSTRUMENTATIONKEY"],
      app_settings["APPLICATIONINSIGHTS_CONNECTION_STRING"],
      app_settings["AzureWebJobsStorage"],
      app_settings["DOCKER_REGISTRY_SERVER_URL"],
      app_settings["DOCKER_REGISTRY_SERVER_USERNAME"],
      app_settings["DOCKER_REGISTRY_SERVER_PASSWORD"],
      storage_account_access_key,
      site_config[0].application_insights_connection_string,
      site_config[0].application_insights_key
    ]
  }

  depends_on = [
    azurerm_role_assignment.function_storage_blob,
    azurerm_role_assignment.function_storage_queue,
    azurerm_role_assignment.function_storage_table,
    azurerm_role_assignment.function_registry_pull
  ]
}

resource "azapi_update_resource" "function_registry_identity" {
  count = local.registry_auth_mode_resolved == "managed_identity" && local.registry_server_normalized != "" ? 1 : 0

  type        = "Microsoft.Web/sites@2024-11-01"
  resource_id = azurerm_linux_function_app.this.id

  body = {
    properties = {
      siteConfig = {
        acrUseManagedIdentityCreds = true
        acrUserManagedIdentityID   = azurerm_user_assigned_identity.function.client_id
      }
    }
  }

  depends_on = [
    azurerm_linux_function_app.this,
    azurerm_role_assignment.function_registry_pull
  ]
}

resource "azurerm_linux_function_app_slot" "staging" {
  count = var.deployment_slot_enabled ? 1 : 0

  name            = var.deployment_slot_name
  function_app_id = azurerm_linux_function_app.this.id

  storage_account_name          = azurerm_storage_account.this.name
  storage_uses_managed_identity = true

  https_only                    = true
  functions_extension_version   = var.functions_extension_version
  public_network_access_enabled = var.public_network_access_enabled
  app_settings                  = local.app_settings

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.function.id]
  }

  site_config {
    always_on                                     = var.plan_sku_name != "Y1"
    container_registry_managed_identity_client_id = local.registry_auth_mode_resolved == "managed_identity" && local.registry_server_normalized != "" ? azurerm_user_assigned_identity.function.client_id : null
    container_registry_use_managed_identity       = local.registry_auth_mode_resolved == "managed_identity" && local.registry_server_normalized != ""
    health_check_path                             = "/healthz/ready"
    health_check_eviction_time_in_min             = 2
    ip_restriction_default_action                 = "Deny"
    scm_ip_restriction_default_action             = "Deny"
    scm_use_main_ip_restriction                   = length(var.scm_allowed_ip_cidrs) == 0

    dynamic "ip_restriction" {
      for_each = { for idx, cidr in var.allowed_ip_cidrs : idx => cidr }

      content {
        name       = "allow-${ip_restriction.key}"
        priority   = 100 + tonumber(ip_restriction.key)
        action     = "Allow"
        ip_address = ip_restriction.value
      }
    }

    dynamic "scm_ip_restriction" {
      for_each = { for idx, cidr in var.scm_allowed_ip_cidrs : idx => cidr }

      content {
        name       = "allow-${scm_ip_restriction.key}"
        priority   = 100 + tonumber(scm_ip_restriction.key)
        action     = "Allow"
        ip_address = scm_ip_restriction.value
      }
    }

    application_stack {
      docker {
        registry_url      = local.slot_image_registry_url
        image_name        = local.slot_image_name
        image_tag         = local.slot_image_tag
        registry_username = local.slot_image_registry_user
        registry_password = local.slot_image_registry_pass
      }
    }
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [
      app_settings["APPINSIGHTS_INSTRUMENTATIONKEY"],
      app_settings["APPLICATIONINSIGHTS_CONNECTION_STRING"],
      app_settings["AzureWebJobsStorage"],
      app_settings["DOCKER_REGISTRY_SERVER_URL"],
      app_settings["DOCKER_REGISTRY_SERVER_USERNAME"],
      app_settings["DOCKER_REGISTRY_SERVER_PASSWORD"],
      storage_account_access_key,
      site_config[0].application_insights_connection_string,
      site_config[0].application_insights_key
    ]
  }

  depends_on = [
    azurerm_role_assignment.function_storage_blob,
    azurerm_role_assignment.function_storage_queue,
    azurerm_role_assignment.function_storage_table,
    azurerm_role_assignment.function_registry_pull
  ]
}

resource "azapi_update_resource" "function_slot_registry_identity" {
  count = var.deployment_slot_enabled && local.registry_auth_mode_resolved == "managed_identity" && local.registry_server_normalized != "" ? 1 : 0

  type        = "Microsoft.Web/sites/slots@2024-11-01"
  resource_id = azurerm_linux_function_app_slot.staging[0].id

  body = {
    properties = {
      siteConfig = {
        acrUseManagedIdentityCreds = true
        acrUserManagedIdentityID   = azurerm_user_assigned_identity.function.client_id
      }
    }
  }

  depends_on = [
    azurerm_linux_function_app_slot.staging,
    azurerm_role_assignment.function_registry_pull
  ]
}

resource "azurerm_role_assignment" "function_storage_blob" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.function.principal_id
}

resource "azurerm_role_assignment" "function_storage_queue" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_user_assigned_identity.function.principal_id
}

resource "azurerm_role_assignment" "function_storage_table" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.function.principal_id
}

resource "azurerm_role_assignment" "function_app_storage_blob" {
  count = var.app_storage_enabled ? 1 : 0

  scope                = azurerm_storage_container.app_storage[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.function.principal_id
}

resource "postgresql_extension" "postgis" {
  count        = var.enable_postgis ? 1 : 0
  provider     = postgresql.honua
  name         = "postgis"
  schema       = "public"
  drop_cascade = true

  depends_on = [
    azurerm_postgresql_flexible_server.this,
    azurerm_postgresql_flexible_server_database.this,
    azurerm_postgresql_flexible_server_configuration.postgis,
  ]
}

resource "postgresql_extension" "postgis_raster" {
  count        = var.enable_postgis ? 1 : 0
  provider     = postgresql.honua
  name         = "postgis_raster"
  schema       = "public"
  drop_cascade = true

  depends_on = [
    azurerm_postgresql_flexible_server.this,
    azurerm_postgresql_flexible_server_database.this,
    azurerm_postgresql_flexible_server_configuration.postgis,
    postgresql_extension.postgis,
  ]
}
