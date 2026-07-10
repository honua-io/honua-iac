# Azure Container Apps Module

Deploys Honua Server to Azure Container Apps with PostgreSQL Flexible Server, Key Vault-backed secrets, optional Azure Cache for Redis, and Log Analytics. The module fails planning when Container Apps could scale past one Honua replica without the required MultiNode, Redis, and shared Azure Blob configuration.

## Pin to a release

For a versioned, external pin, consume this module by Git source at a SemVer tag
instead of a relative path. (The Honua repos are ELv2-licensed, so the public
Terraform Registry is not used — see
[`docs/module-versioning.md`](../../../../docs/module-versioning.md).)

```hcl
module "honua" {
  source = "git::https://github.com/honua-io/honua-iac.git//infrastructure/terraform/modules/azure-aca?ref=v0.1.0"
  # ...inputs below...
}
```

Bump `?ref=` to move to a newer release and run `terraform init -upgrade`.

## Quick start (dev)

```hcl
module "honua" {
  source = "../../modules/azure-aca"

  environment    = "dev"
  location       = "eastus"
  image          = "ghcr.io/honua-io/honua-server:v1.2.3-aot"
  admin_password = var.honua_admin_password
  enable_postgis = true  # Required — Honua needs PostGIS + PostGIS Raster

  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI       = "true"
  }
}
```

> **PostGIS + PostGIS Raster are required.** Set `enable_postgis = true` to enable both extensions via a local-exec provisioner. This requires `psql` on the machine running `terraform apply` and network access to the database. If you cannot run local-exec, enable both extensions manually after apply.

## Production example

```hcl
module "honua" {
  source = "../../modules/azure-aca"

  environment = "prod"
  location    = "eastus"
  name_prefix = "honua"

  # Container
  image            = "ghcr.io/honua-io/honua-server:v1.2.3-aot"  # Pin to a release AOT tag
  container_cpu    = 1.0     # 1 vCPU
  container_memory = "2Gi"
  min_replicas     = 2       # Minimum 2 for HA
  max_replicas     = 10
  deployment_mode  = "MultiNode"

  # Database
  admin_password                = var.honua_admin_password
  db_sku_name                   = "GP_Standard_D2s_v3"   # General Purpose, production-grade
  db_storage_mb                 = 65536                   # 64 GB
  db_version                    = "16"
  db_geo_redundant_backup_enabled = true
  enable_postgis                = true

  # Redis (multi-node caching)
  redis_enabled  = true
  redis_sku_name = "Standard"
  redis_capacity = 2

  # Shared file storage (existing account/container; connection is Key Vault-backed)
  file_storage_provider                     = "AzureBlob"
  file_storage_azure_blob_connection_string = var.file_storage_connection_string
  file_storage_azure_blob_container_name    = "honua-prod-files"

  # Networking
  enable_ingress        = true
  db_public_network_access = false  # Use private access in production

  # Key Vault
  key_vault_purge_protection_enabled = true
  key_vault_default_action           = "Deny"

  # Monitoring
  log_analytics_enabled = true

  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI      = "true"
    HONUA_OBSERVABILITY = "true"
    Public__BaseUrl     = "https://gis.example.com"
  }

  tags = {
    Project     = "honua"
    Environment = "prod"
  }
}
```

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `image` | Required | Container image. Pin to an immutable release tag or digest. AOT builds are recommended. |
| `container_cpu` | 0.5 | CPU cores (0.25, 0.5, 1.0, 2.0, 4.0). |
| `container_memory` | `"1Gi"` | Memory with `Gi` suffix (for example `1Gi`, `1.5Gi`). |
| `min_replicas` / `max_replicas` | 1 / 1 | Scaling range. Any value greater than one requires the safe MultiNode topology. |
| `deployment_mode` | `SingleInstance` | Honua runtime mode. Set `MultiNode` for HA or auto-scaling. |
| `file_storage_provider` | `Local` | File storage backend. MultiNode requires `AzureBlob`. |
| `file_storage_azure_blob_connection_string` | `""` | Existing Azure Storage account connection string. Required with `AzureBlob` and stored in Key Vault. |
| `file_storage_azure_blob_container_name` | `""` | Existing shared blob container. Required with `AzureBlob`. |
| `file_storage_azure_blob_prefix` | `honua` | Optional object prefix within the shared container. |
| `enable_postgis` | **false** | Enable PostGIS + PostGIS Raster extensions. **Set to true.** |
| `existing_db_connection_string` + `existing_db_fqdn` | `""` | Reuse an existing PostgreSQL server and skip DB creation/bootstrap. |
| `db_sku_name` | `B_Standard_B1ms` | PostgreSQL SKU. Use `GP_Standard_*` for production. |
| `db_storage_mb` | 32768 | Database storage in MB. |
| `db_geo_redundant_backup_enabled` | true | Geo-redundant backups. |
| `redis_enabled` | true | Provision Azure Cache for Redis. |
| `redis_connection_string` | `""` | Reuse an existing Redis instance instead of provisioning one. |
| `redis_sku_name` | `Standard` | Redis SKU (Basic, Standard, Premium). |
| `key_vault_default_action` | `Deny` | Key Vault network ACL default. |
| `enable_ingress` | true | Expose Container App via external ingress. |
| `log_analytics_enabled` | true | Enable Log Analytics workspace. |

See `variables.tf` for the complete list.

## Key Vault networking

Key Vault network ACLs default to `Deny`. Adjust `key_vault_ip_rules` to allowlist your CI/CD runner IPs, or supply private endpoints outside the module.

## Private container registry

For private registries (e.g. ACR), provide credentials:

```hcl
registry_server   = "myregistry.azurecr.io"
registry_username = var.acr_username
registry_password = var.acr_password
```

## Outputs

See `outputs.tf` for the Container App FQDN, Key Vault secret IDs, and database connection string. The module also emits Honua control-plane handoff metadata:

- `environment`
- `container_app_name`
- `container_app_id`
- `container_app_environment_id`
- `control_plane_target_kind = "AzureContainerApps"`
- `control_plane_backend_name = "honua-gitops-azure-container-apps"`
- `control_plane_target_id`
- `control_plane_target_name` and `control_plane_target_resource_id`
- `control_plane_target_resource_group`
- `control_plane_telemetry_policy = "honua-http"`

## After apply

1. Verify extensions: `psql $CONNECTION_STRING -c "SELECT PostGIS_Version(); SELECT extname FROM pg_extension WHERE extname IN ('postgis','postgis_raster');"`
2. Health check: `curl -f https://<app-fqdn>/healthz/ready`
3. If using OIDC, configure env vars per [Security Configuration](../../../../docs/devops/security.md)
