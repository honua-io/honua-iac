# Azure Functions (Serverless) Module

Deploys Honua Server to Azure Functions (custom container) with PostgreSQL Flexible Server, optional Azure Cache for Redis, and Application Insights.

## Quick start

```hcl
module "honua" {
  source = "../../modules/azure-functions"

  environment    = "dev"
  location       = "eastus"
  image          = "myregistry.azurecr.io/honua-server:v1.2.3-aot"
  admin_password = var.honua_admin_password
  enable_postgis = true  # Required — Honua needs PostGIS + PostGIS Raster

  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI       = "true"
  }
}
```

## Prerequisites

- **PostGIS + PostGIS Raster**: Set `enable_postgis = true` so Terraform's `postgresql_extension` resources create the extensions without needing `psql`. When reusing an existing PostgreSQL server, provide `existing_db_connection_string` together with `existing_db_admin_password` so the provider can authenticate automatically.
- **Migrations**: `skip_migrations` defaults to `true` for serverless. Run migrations out-of-band before first use.
- **Custom container**: The image must be compatible with the Azure Functions custom handler model (`FUNCTIONS_WORKER_RUNTIME=custom`).

## Production example

```hcl
module "honua" {
  source = "../../modules/azure-functions"

  environment = "prod"
  location    = "eastus"
  name_prefix = "honua"

  # Function App
  image         = "myregistry.azurecr.io/honua-server:v1.2.3-aot"  # Pin to a release AOT tag
  plan_sku_name = "EP1"    # Premium plan (recommended for predictable cold starts)

  # Database
  admin_password                    = var.honua_admin_password
  db_sku_name                       = "GP_Standard_D2s_v3"
  db_storage_mb                     = 65536
  db_geo_redundant_backup_enabled   = true
  enable_postgis                    = true
  skip_migrations                   = true

  # Redis
  redis_enabled  = true
  redis_sku_name = "Standard"
  redis_capacity = 2

  # Monitoring
  app_insights_enabled = true

  additional_env = {
    HONUA_OBSERVABILITY = "true"
    Public__BaseUrl     = "https://gis.example.com"
  }
}
```

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `image` | Required | Container image. Pin to an immutable release tag or digest. Prefer AOT builds; use JIT images only for debug fallback. |
| `deployment_slot_enabled` | false | Provision a staging slot for slot-based rollout workflows. |
| `deployment_slot_name` | `staging` | Name of the optional staging slot. |
| `deployment_slot_image` | `""` | Optional container image for the staging slot. Defaults to `image` when empty. |
| `plan_sku_name` | `EP1` | Premium (`EP1`–`EP3`) or Consumption (`Y1`). Premium recommended. |
| `enable_postgis` | **false** | Enable PostGIS + PostGIS Raster on database. **Set to true.** |
| `skip_migrations` | true | Skip auto-migrations. Run them out-of-band for serverless. |
| `existing_db_connection_string` + `existing_db_fqdn` | `""` | Reuse an existing PostgreSQL server and skip DB creation/bootstrap. When `enable_postgis = true`, also set `existing_db_admin_password` so the PostgreSQL provider can enable the extensions. |
| `existing_db_admin_password` | `""` | Admin password for the reused PostgreSQL server. Required when `enable_postgis = true`. |
| `db_sku_name` | `B_Standard_B1ms` | PostgreSQL SKU. Use `GP_Standard_*` for production. |
| `db_geo_redundant_backup_enabled` | true | Geo-redundant backups. |
| `redis_enabled` | true | Provision Azure Cache for Redis. |
| `redis_connection_string` | `""` | Reuse an existing Redis instance instead of provisioning one. |
| `app_insights_enabled` | true | Enable Application Insights. |

See `variables.tf` for the complete list.

## Plan selection

| SKU | Cold start | Scale | Recommended for |
|-----|-----------|-------|-----------------|
| `EP1`–`EP3` | Warm instances, faster | Auto-scale with min instances | Production |
| `Y1` | Cold start on every scale event | Auto-scale, stricter limits | Dev/testing, cost-sensitive |

## Cold starts

Use AOT images such as `vX.Y.Z-aot` for runtime performance. Use JIT images only for debug fallback.

## Private container registry

For ACR or other private registries:

```hcl
registry_server   = "myregistry.azurecr.io"
registry_username = var.acr_username
registry_password = var.acr_password
```

Operational guidance:

- Prefer a dedicated pull identity over an ACR admin user.
- Use the same registry credential set for both the primary image and the optional deployment slot unless you intentionally split promotion lanes.
- When rotating registry credentials, update the Terraform inputs and re-apply before deleting the old credential.

## Outputs

See `outputs.tf` for the Function App URL, database connection string, and Redis endpoint. The module also emits Honua control-plane handoff metadata:

- `environment`
- `function_app_name`
- `function_app_id`
- `control_plane_target_kind = "AzureFunctions"`
- `control_plane_backend_name = "honua-gitops-azure-functions"`
- `control_plane_target_id`
- `control_plane_target_name` and `control_plane_target_resource_id`
- `control_plane_target_resource_group`
- `control_plane_telemetry_policy = "honua-http"`
- `control_plane_current_revision = "production"` when `deployment_slot_enabled = true`
- `control_plane_desired_revision = <slot-name>` when `deployment_slot_enabled = true`
- `control_plane_current_image` and `control_plane_desired_image` for provider-side slot observation
- `control_plane_slot_name` plus `function_app_slot_name` / `function_app_slot_id` when `deployment_slot_enabled = true`

## Slot-based rollouts

Set `deployment_slot_enabled = true` to provision a staging slot that can hold the next Honua image separately from production. This module does not perform slot swaps itself. Instead, it emits the slot metadata the Honua control plane or future GitOps controller can use to plan and observe a slot-based rollout.

## Backup, restore, and secret rotation

This module provisions PostgreSQL Flexible Server and stores runtime secrets in Key Vault, but backup and credential lifecycle remain operator responsibilities.

### Backup and restore

- Use Flexible Server PITR or a manual backup/snapshot before risky schema changes.
- Restore to a new server, not in place.
- Repoint the module with `existing_db_fqdn` and `existing_db_connection_string`, then apply again so the Function App settings and Key Vault references converge on the restored database.
- Redis should usually be treated as disposable cache state. If you retain it, restore it outside this module and update `redis_connection_string` before re-applying.

### Credential rotation

- Rotate `admin_password`, database credentials, and `registry_*` inputs one class at a time.
- Apply Terraform after each rotation so Key Vault secrets and app settings stay aligned.
- If slots are enabled, verify both production and staging after rotation because slot image auth and slot app settings are independent execution paths.

## Cross-cloud parity notes

Compared with the AWS Lambda module:

- Azure Functions uses Key Vault references instead of Secrets Manager ARNs.
- Azure Functions supports an optional deployment slot workflow; AWS Lambda uses published versions plus alias movement.
- Both serverless modules default to out-of-band migrations for production and expect immutable container images.

For broader operator procedures and target selection, use `docs/operator-deployment.md`.
