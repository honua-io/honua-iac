data "azurerm_client_config" "current" {}

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
  db_use_existing            = var.existing_db_connection_string != ""
  app_storage_account_name   = var.app_storage_enabled ? substr(replace(lower("${var.name_prefix}${var.environment}app${random_string.app_storage_suffix[0].result}"), "-", ""), 0, 24) : null
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
    error_message = "existing_db_admin_password or db_admin_password must be set when enable_postgis is true on an existing database."
  }
}

check "db_public_access_requires_firewall_rule" {
  assert {
    condition     = local.db_use_existing || !var.db_public_network_access || (trimspace(var.db_firewall_start_ip) != "" && trimspace(var.db_firewall_end_ip) != "")
    error_message = "db_firewall_start_ip and db_firewall_end_ip must be set when db_public_network_access is true."
  }
}

check "redis_reuse_is_exclusive" {
  assert {
    condition     = !(var.redis_enabled && trimspace(var.redis_connection_string) != "")
    error_message = "redis_enabled and redis_connection_string are mutually exclusive; set only one."
  }
}

check "replica_bounds" {
  assert {
    condition     = var.max_replicas >= var.min_replicas
    error_message = "max_replicas must be greater than or equal to min_replicas."
  }
}

check "ingress_requires_allowed_cidrs" {
  assert {
    condition     = !var.enable_ingress || length(var.ingress_allowed_cidrs) > 0
    error_message = "ingress_allowed_cidrs must be set when enable_ingress is true."
  }
}

check "key_vault_diagnostics_requires_workspace" {
  assert {
    condition     = !var.key_vault_diagnostics_enabled || trimspace(var.key_vault_diagnostics_workspace_id) != "" || var.log_analytics_enabled
    error_message = "key_vault_diagnostics_enabled requires log_analytics_enabled or key_vault_diagnostics_workspace_id."
  }
}

resource "azurerm_resource_group" "this" {
  name     = "${local.name}-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_user_assigned_identity" "this" {
  name                = "${local.name}-identity"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "registry_pull" {
  count = local.registry_auth_mode_resolved == "managed_identity" && trimspace(var.registry_resource_id) != "" ? 1 : 0

  scope                = var.registry_resource_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
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
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  tags                            = local.tags

  network_rules {
    default_action = var.app_storage_default_action
    bypass         = ["AzureServices"]
    ip_rules       = var.app_storage_ip_rules
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

#checkov:skip=CKV_AZURE_189: Private endpoints are configured outside this module.
#checkov:skip=CKV2_AZURE_32: Private endpoints are configured outside this module.
resource "azurerm_key_vault" "this" {
  #checkov:skip=CKV_AZURE_189: Private endpoints are configured outside this module.
  #checkov:skip=CKV2_AZURE_32: Private endpoints are configured outside this module.
  name                          = "${local.name}-kv"
  location                      = azurerm_resource_group.this.location
  resource_group_name           = azurerm_resource_group.this.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  purge_protection_enabled      = var.key_vault_purge_protection_enabled
  soft_delete_retention_days    = var.key_vault_soft_delete_retention_days
  public_network_access_enabled = var.key_vault_public_network_access_enabled

  network_acls {
    default_action = var.key_vault_default_action
    bypass         = var.key_vault_bypass
    ip_rules       = var.key_vault_ip_rules
  }

  tags = local.tags
}

resource "azurerm_key_vault_access_policy" "current" {
  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = [
    "Get",
    "List",
    "Set",
    "Delete",
    "Purge",
    "Recover"
  ]
}

resource "azurerm_key_vault_access_policy" "identity" {
  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.this.principal_id

  secret_permissions = [
    "Get"
  ]
}

resource "azurerm_role_assignment" "app_storage_blob" {
  count = var.app_storage_enabled ? 1 : 0

  scope                = azurerm_storage_container.app_storage[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
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
    var.log_analytics_enabled ? azurerm_log_analytics_workspace.this[0].id : null
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

  backup_retention_days = var.db_backup_retention_days

  public_network_access_enabled = var.db_public_network_access
  geo_redundant_backup_enabled  = var.db_geo_redundant_backup_enabled

  tags = local.tags
}

resource "azurerm_postgresql_flexible_server_configuration" "require_secure_transport" {
  count     = local.db_use_existing ? 0 : 1
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.this[0].id
  value     = "on"
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

resource "azurerm_postgresql_flexible_server_configuration" "postgis" {
  count     = !local.db_use_existing && var.enable_postgis ? 1 : 0
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.this[0].id
  value     = "POSTGIS,POSTGIS_RASTER"
}

resource "azurerm_redis_cache" "this" {
  #checkov:skip=CKV_AZURE_89: Public access can be enabled for MVP deployments; private endpoints configured externally.
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

resource "azurerm_key_vault_secret" "db_connection" {
  name            = "honua-db-connection"
  value           = local.db_connection_string
  content_type    = "connection-string"
  expiration_date = local.secret_expiration_date
  key_vault_id    = azurerm_key_vault.this.id
  depends_on      = [azurerm_key_vault_access_policy.identity, azurerm_key_vault_access_policy.current]
}

resource "azurerm_key_vault_secret" "admin_password" {
  name            = "honua-admin-password"
  value           = var.admin_password
  content_type    = "password"
  expiration_date = local.secret_expiration_date
  key_vault_id    = azurerm_key_vault.this.id
  depends_on      = [azurerm_key_vault_access_policy.identity, azurerm_key_vault_access_policy.current]
}

resource "azurerm_key_vault_secret" "connection_encryption_master_key" {
  name            = "honua-connection-encryption-master-key"
  value           = local.connection_encryption_master_key
  content_type    = "password"
  expiration_date = local.secret_expiration_date
  key_vault_id    = azurerm_key_vault.this.id
  depends_on      = [azurerm_key_vault_access_policy.identity, azurerm_key_vault_access_policy.current]
}

resource "azurerm_key_vault_secret" "redis_connection" {
  count           = local.redis_enabled ? 1 : 0
  name            = "honua-redis-connection"
  value           = local.redis_connection
  content_type    = "connection-string"
  expiration_date = local.secret_expiration_date
  key_vault_id    = azurerm_key_vault.this.id
  depends_on      = [azurerm_key_vault_access_policy.identity, azurerm_key_vault_access_policy.current]
}

resource "azurerm_log_analytics_workspace" "this" {
  count               = var.log_analytics_enabled ? 1 : 0
  name                = "${local.name}-logs"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  count                      = var.key_vault_diagnostics_enabled && (trimspace(var.key_vault_diagnostics_workspace_id) != "" || var.log_analytics_enabled) ? 1 : 0
  name                       = "${local.name}-kv-diagnostics"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = local.key_vault_diagnostics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }
}

resource "azurerm_container_app_environment" "this" {
  name                = "${local.name}-env"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  log_analytics_workspace_id = var.log_analytics_enabled ? azurerm_log_analytics_workspace.this[0].id : null

  tags = local.tags
}

resource "azurerm_container_app" "this" {
  name                         = "${local.name}-app"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  dynamic "registry" {
    for_each = toset(local.registry_server_normalized != "" ? ["registry"] : [])
    content {
      server               = local.registry_server_normalized
      identity             = local.registry_auth_mode_resolved == "managed_identity" ? azurerm_user_assigned_identity.this.id : null
      username             = local.registry_auth_mode_resolved == "username_password" ? var.registry_username : null
      password_secret_name = local.registry_auth_mode_resolved == "username_password" ? "registry-password" : null
    }
  }

  secret {
    name  = "db-connection"
    value = local.db_connection_string
  }

  secret {
    name  = "admin-password"
    value = var.admin_password
  }

  secret {
    name  = "connection-encryption-master-key"
    value = local.connection_encryption_master_key
  }

  dynamic "secret" {
    for_each = toset(local.redis_enabled ? ["redis"] : [])
    content {
      name  = "redis-connection"
      value = local.redis_connection
    }
  }

  dynamic "secret" {
    for_each = toset(local.registry_auth_mode_resolved == "username_password" ? ["registry"] : [])
    content {
      name  = "registry-password"
      value = var.registry_password
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    http_scale_rule {
      name                = "http-scaling"
      concurrent_requests = var.scaling_concurrent_requests
    }

    container {
      name   = "honua"
      image  = var.image
      cpu    = var.container_cpu
      memory = var.container_memory

      env {
        name        = "ConnectionStrings__DefaultConnection"
        secret_name = "db-connection"
      }

      env {
        name        = "HONUA_ADMIN_PASSWORD"
        secret_name = "admin-password"
      }

      env {
        name        = "Security__ConnectionEncryption__MasterKey"
        secret_name = "connection-encryption-master-key"
      }

      dynamic "env" {
        for_each = toset(local.redis_enabled ? ["redis"] : [])
        content {
          name        = "ConnectionStrings__redis"
          secret_name = "redis-connection"
        }
      }

      dynamic "env" {
        for_each = var.additional_env
        content {
          name  = env.key
          value = env.value
        }
      }

      liveness_probe {
        transport = "HTTP"
        path      = "/healthz/live"
        port      = var.container_port

        initial_delay           = 10
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 3
      }

      readiness_probe {
        transport = "HTTP"
        path      = "/healthz/ready"
        port      = var.container_port

        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 3
      }

      startup_probe {
        transport = "HTTP"
        path      = "/healthz/live"
        port      = var.container_port

        initial_delay           = var.startup_probe_initial_delay_seconds
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = var.startup_probe_failure_threshold
      }
    }
  }

  ingress {
    external_enabled           = var.enable_ingress
    allow_insecure_connections = false
    target_port                = var.container_port
    transport                  = "auto"

    dynamic "ip_security_restriction" {
      for_each = { for idx, cidr in var.ingress_allowed_cidrs : idx => cidr }

      content {
        action           = "Allow"
        name             = "allow-${ip_security_restriction.key}"
        ip_address_range = ip_security_restriction.value
      }
    }

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  tags = local.tags

  depends_on = [
    azurerm_key_vault_access_policy.identity,
    azurerm_role_assignment.registry_pull
  ]
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
