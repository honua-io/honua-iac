# Azure Container Apps Module

Preview. Not a qualified 2026.1 target. The module still declares `Licensing__Mode=Disabled` so a stack does not boot the server's Community default.

Deploys Honua Server to Azure Container Apps with PostgreSQL Flexible Server, Key Vault-backed secrets, optional Azure Cache for Redis, and Log Analytics. The module fails planning when Container Apps could scale past one Honua replica without the required MultiNode, Redis, and shared Azure Blob configuration.

## Pin to a release

For a versioned, external pin, consume this module by Git source at a SemVer tag
instead of a relative path. (The Honua repos are FCL-1.0-ALv2-licensed, so the public
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
  image          = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password = var.honua_admin_password
  connection_encryption_master_key = null # Deliberate auto-generation for this new deployment
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
  image            = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" # Published digest. No v* honua-server tag exists.
  container_cpu    = 1.0     # 1 vCPU
  container_memory = "2Gi"
  min_replicas     = 2       # Minimum 2 for HA
  max_replicas     = 10
  deployment_mode  = "MultiNode"

  # Database
  admin_password                   = var.honua_admin_password
  connection_encryption_master_key = var.honua_connection_encryption_master_key
  db_sku_name                      = "GP_Standard_D2s_v3"   # General Purpose, production-grade
  db_storage_mb                    = 65536                   # 64 GB
  db_version                       = "16"
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
| `image` | Required | Container image. Pin the published digest (`name@sha256:<64 hex>`). No `v*` honua-server tag exists. |
| `licensing_mode` | `Disabled` | Declared as `Licensing__Mode`. Disabled is the 2026.1 contract. The server default is Enabled and boots Community. |
| `connection_encryption_master_key` | Required (nullable) | Fail-closed connection-key decision. Set `null` explicitly only for a new deployment; existing deployments must supply their current key as described below. |
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
| `request_secret_reference_allowed_environment_variables` | `[]` | Exact environment variable names a request may name as `env:NAME`. Rendered as `Security__RequestSecretReferences__AllowedEnvironmentVariables__<n>`. |
| `request_secret_reference_allowed_environment_variable_prefixes` | `[]` | Environment variable name prefixes a request may name as `env:NAME` (never matches a name containing `__`). Rendered as `Security__RequestSecretReferences__AllowedEnvironmentVariablePrefixes__<n>`. |
| `request_secret_reference_allowed_secret_reference_prefixes` | `[]` | Whole-reference prefixes for the other providers, including the provider segment, e.g. `azure:keyvault:honua-imports:`. Rendered as `Security__RequestSecretReferences__AllowedSecretReferencePrefixes__<n>`. |

See `variables.tf` for the complete list.

## Request-supplied secret references

The three `request_secret_reference_allowed_*` variables are the allowlist for
request-supplied secret references (honua-server #5055) and bind the server's
`Security:RequestSecretReferences` section. The server policy is deny-by-default:
with all three lists empty (the default, which renders nothing) the server
resolves no secret reference named in a request - import credentials, workflow
source steps, secure-connection registration - and a secure connection that
stores a `secretReference` does not resolve it at runtime. Connections stored
with an encrypted password, and secret references in the server's own
configuration, are not governed by this policy.

```hcl
request_secret_reference_allowed_environment_variable_prefixes = ["HONUA_IMPORT_"]
request_secret_reference_allowed_secret_reference_prefixes     = ["azure:keyvault:honua-imports:"]
```

Entries are rendered in list order into the container environment. For
the whole-reference list the provider (the text before the first colon) is
matched case-insensitively and the remainder is a case-sensitive prefix of the
reference, so an entry must have the same form as the references it is meant to
permit. Keep entries as narrow as the deployment allows, and
give imports and connections their own variables or secret path rather than
listing the server's own credentials. Set the entries through these variables or
through `additional_env`, not both, so one source owns the indexes.

An allowed `azure:` reference is resolved in-process as the module's
user-assigned identity; the module sets `AZURE_CLIENT_ID` to select it whenever
an `azure:` entry is allowlisted. Grant that identity read access (for example
Key Vault Secrets User) on any vault other than this module's.

Server images that predate the setting ignore these variables, so they can be
set before upgrading; deployments that already rely on request-supplied
references should set matching entries before moving to an image that includes
the setting.

## Upgrade from the aliased connection key

Adding this required input is an intentionally breaking-but-safe module contract. Omission fails planning instead of silently replacing a deployed key. Earlier module versions used `admin_password` as `Security__ConnectionEncryption__MasterKey`. To avoid making existing encrypted connection records unreadable:

1. Before the first apply with this module version, set `connection_encryption_master_key` to the deployment's current connection encryption key. For deployments created by an earlier module version, that value is the current `admin_password`.
2. Apply and verify that the Container App now references the separate Key Vault secret while its value remains unchanged.
3. Rotate the key only with Honua's supported key rotation and re-encryption procedure. Do not rotate it by changing this Terraform input alone.

Brand-new deployments must set the input explicitly to `null`; Terraform then generates and stores an independent 32-character key. Never use `null` while upgrading an existing deployment.

## Key Vault networking

Key Vault network ACLs default to `Deny`. Adjust `key_vault_ip_rules` to allowlist your CI/CD runner IPs, or supply private endpoints outside the module.

## Private container registry

For private registries (e.g. ACR), provide credentials:

```hcl
registry_server   = "myregistry.azurecr.io"
registry_username = var.acr_username
registry_password = var.acr_password
```

## Database connection sizing

honua-server sizes every Npgsql pool from `Limits:Connections`, and its
defaults are generous: `MaxConnectionPoolSize` 200 and `MinConnectionPoolSize`
20 per pool. Each server process opens at least two pools on the database
(the main data source, and the pool keyed by its connection string that the
publish, import and migration paths open directly; each bound secure
connection adds one more). Left at the defaults, a few processes exhaust a
small database with PostgreSQL `53300` (on the public demo the FeatureServer
then answered `Query execution failed` inside HTTP 200).

The module sizes the pools from its own inputs (`db-pool-sizing.tf`; the
shared block is identical in `aws-serverless`, `aws-ecs`, `aws-eks`,
`azure-aca` and `azure-functions`):

```
usable           = max_connections - reserved
per_process_pool = floor((floor(usable x db_connection_safety_fraction) - other_connections)
                         / (max_processes x db_pools_per_process))
                   clamped to [1, 200]
```

and renders `Limits__Connections__MaxConnectionPoolSize` and
`Limits__Connections__MaxConcurrentQueries` (equal: the server refuses to
start when the query limit exceeds the pool), plus `MinConnectionPoolSize` (`min(20, pool)`). `max_connections` comes from
a table, or `db_max_connections_override`:

- **RDS for PostgreSQL**: `LEAST({DBInstanceClassMemory/9531392}, 5000)`
  ([RDS limits](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html#RDS_Limits.MaxConnections)),
  computed from 75% of the class's nominal memory because
  `DBInstanceClassMemory` excludes what the OS and RDS keep (observed:
  `db.t3.micro` 87 and `db.t4g.small` about 180, the table gives 84 and 168).
  Families t3/t4g, m5/m6g/m6i/m7g/m7i and r5/r6g/r6i/r7g/r7i; 5 reserved
  (`superuser_reserved_connections` 3 + `rds.rds_superuser_reserved_connections` 2).
  Aurora is not provisioned by these modules.
- **Azure Database for PostgreSQL flexible server**: the documented default per
  SKU ([limits](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-limits#maximum-connections)),
  `B_Standard_B1ms` 50 up to 5000; 15 reserved.

| Input | Default | Meaning |
|-------|---------|---------|
| `db_pool_size_override` | `null` | Pool size to render instead of the derived one. |
| `db_connection_pooler_enabled` | `false` | The server reaches PostgreSQL through a pooler (for example the flexible server's built-in PgBouncer, not available on Burstable); skips the budget check. |
| `db_max_connections_override` | `null` | `max_connections` to size from (custom parameter, a class/SKU missing from the table, or an existing database). |
| `db_pools_per_process` | `2` | Pools each server process opens. |
| `db_connection_safety_fraction` | `0.85` | Share of the usable connections the server pools may take; the rest is for migrations, bootstrap and operator sessions. |

`plan` fails (a precondition on the `db_connection_budget` output) when
`max_processes x db_pools_per_process x pool + other_connections` exceeds the
usable connections, unless `db_connection_pooler_enabled`. The derived pool only fails it when even a pool of 1
does not fit; an override that is too large always does. The
`db_connection_budget` output reports every term and `source`: `derived`,
`override`, `fallback` (the module's previous value) or `server-default` (no
keys rendered). Sizing needs a known `max_connections` and a bounded process
count; without either the module renders what it rendered before.

**Processes.** `max_replicas`, doubled because `revision_mode = "Single"`
keeps the old revision's replicas until the new one is ready. With
`existing_db_fqdn` set `db_max_connections_override` too, or the server
defaults stay.

**Example.** The defaults (`B_Standard_B1ms`, one replica): 50 - 15 = 35 usable,
`floor(35 x 0.85) = 29`, `29 / (2 x 2) = 7` per pool.

**Upgrade note.** The container gains the three `Limits__Connections__*`
entries (a new revision); nothing else changes. A `Limits__Connections__*` key
in `additional_env` wins and the module then omits its own; a hand-set
`MaxConnectionPoolSize` is what the budget check counts.

## Redis connections

Redis needs no pool formula: each server process holds one StackExchange.Redis
multiplexer for infrastructure (events, coordination) and a second one for the
distributed cache when that is enabled, about two sockets each, so roughly
**4 connections per process** whatever the request concurrency. Budget
`max processes x 4` against the Redis server's client limit. Azure Cache for Redis limits connections by size (Basic/Standard C0 256, C1 1,000, C2 2,000, C3 5,000; see [Azure Cache for Redis limits](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/cache-planning-faq)), which `processes x 4` must stay under. In a non-Development environment with Redis configured the server requires durable distributed events, so Redis is a hard startup dependency for every replica.

The server forces only `abortConnect=false`, `connectRetry>=3` and an
exponential reconnect policy; timeouts come from the connection string. The
string this module builds therefore ends with
`,connectTimeout=5000,syncTimeout=10000,keepAlive=60`
(`redis_connect_timeout_ms`, `redis_sync_timeout_ms`,
`redis_keep_alive_seconds`); the 5000 ms `syncTimeout` default has timed out
under load (honua-server PR #4967). It is stored in the connection secret, not
in the process environment. A caller-supplied `redis_connection_string` is used
unchanged. Existing deployments see an in-place update of that secret.

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
2. Readiness check: call `HonuaClient("https://<app-fqdn>").readiness()` from the supported Python SDK.
3. If using OIDC, configure env vars per [Security Configuration](../../../../docs/devops/security.md)
