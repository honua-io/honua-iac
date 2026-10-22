# AWS ECS/Fargate Module

Provisions Honua Server on ECS/Fargate with an ALB, RDS PostgreSQL, optional ElastiCache Redis, and supporting infrastructure (VPC, secrets, logging). The module fails planning when ECS could run multiple Honua tasks without the required MultiNode, Redis, and shared S3 configuration.

## Pin to a release

For a versioned, external pin, consume this module by Git source at a SemVer tag
instead of a relative path. (The Honua repos are ELv2-licensed, so the public
Terraform Registry is not used — see
[`docs/module-versioning.md`](../../../../docs/module-versioning.md).)

```hcl
module "honua" {
  source = "git::https://github.com/honua-io/honua-iac.git//infrastructure/terraform/modules/aws-ecs?ref=v0.1.0"
  # ...inputs below...
}
```

Bump `?ref=` to move to a newer release and run `terraform init -upgrade`.

## Quick start (dev)

```hcl
module "honua" {
  source = "../../modules/aws-ecs"

  environment    = "dev"
  image          = "123456789012.dkr.ecr.us-west-2.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password = var.honua_admin_password
  connection_encryption_master_key = null # Deliberate auto-generation for this new deployment
  enable_postgis = true  # Required — Honua needs PostGIS + PostGIS Raster

  # Optional caller-owned AI provider credential. Only the ARN is passed to Terraform.
  ai_provider_secret_arn         = var.ai_provider_secret_arn
  ai_provider_secret_kms_key_arn = var.ai_provider_secret_kms_key_arn

  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI       = "true"
  }
}
```

> **PostGIS + PostGIS Raster are required.** Set `enable_postgis = true` to enable both extensions on the RDS instance via a local-exec provisioner. This requires `psql` on the machine running `terraform apply` and network access to the RDS endpoint. If you cannot run local-exec, enable both extensions manually after apply. For controlled temporary access from CI/local runners, use `db_additional_ingress_cidrs`.
>
> If you do not set `allow_http_ingress_cidrs` or `allow_https_ingress_cidrs`, the ALB listener defaults to VPC-only ingress using the active VPC CIDR. Set explicit CIDRs before exposing the service more broadly.

## Production example

```hcl
module "honua" {
  source = "../../modules/aws-ecs"

  environment = "prod"
  name_prefix = "honua"

  # Container
  image            = "123456789012.dkr.ecr.us-west-2.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" # Published digest. No v* honua-server tag exists.
  container_cpu    = 1024   # 1 vCPU
  container_memory = 2048   # 2 GB
  desired_count    = 2      # Minimum 2 for HA
  max_capacity     = 4
  deployment_mode  = "MultiNode"

  # Database
  admin_password                   = var.honua_admin_password
  connection_encryption_master_key = var.honua_connection_encryption_master_key
  db_instance_class                = "db.r6g.large"    # Production-grade instance
  db_allocated_storage             = 100               # GB
  db_multi_az                      = true              # Failover replica
  db_require_ssl                   = true
  enable_postgis                   = true

  # Redis (multi-node caching)
  redis_enabled            = true
  redis_node_type          = "cache.r6g.large"
  redis_num_cache_clusters = 2

  # Shared file storage (existing bucket; the module grants task-role access)
  file_storage_provider           = "AwsS3"
  file_storage_aws_s3_bucket_name = "honua-prod-files"
  file_storage_aws_s3_region      = "us-west-2"

  # Networking
  vpc_cidr             = "10.0.0.0/16"
  enable_nat_gateway   = true
  assign_public_ip     = false

  # HTTPS
  alb_certificate_arn     = var.acm_certificate_arn
  alb_deletion_protection = true

  # Logging and monitoring
  log_retention_days         = 365
  enable_container_insights  = true
  alb_access_logs_enabled    = true

  # Optional ALB canary path
  canary_enabled           = true
  canary_image             = "123456789012.dkr.ecr.us-west-2.amazonaws.com/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  canary_desired_count     = 1
  canary_weight_percentage = 0

  # Security
  waf_web_acl_arn = var.waf_acl_arn  # Optional WAFv2

  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI       = "true"
    HONUA_OBSERVABILITY  = "true"
    HONUA_OPENTELEMETRY  = "true"
  }

  tags = {
    Project     = "honua"
    Environment = "prod"
  }
}
```

## HTTPS

Provide an ACM certificate for the HTTPS listener:

```hcl
alb_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/..."
```

HTTP-to-HTTPS redirect is enabled by default when a certificate is provided. Disable with `alb_enable_http_redirect = false`.

### TLS termination at the ALB

The ALB terminates TLS and forwards plain HTTP to the task. With any certificate
(`alb_certificate_arn`, or the managed certificate below) the module sets on
both the stable and canary task definitions:

| Variable | Value | Why |
|----------|-------|-----|
| `SecurityHeaders__HstsHttpsOnly` | `false` | Emit `Strict-Transport-Security` even though the in-VPC hop is HTTP (the same contract as `modules/aws-serverless`). |
| `ASPNETCORE_FORWARDEDHEADERS_ENABLED` | `true` | Honour the ALB's `X-Forwarded-Proto` and `X-Forwarded-For`, so the request scheme is `https` and the client IP is the caller's. The ALB preserves `Host`. |

The forwarded headers are trusted from any peer because the task security group
admits the container port only from the ALB security group; ALB node IPs change,
so a fixed `ForwardedHeaders__KnownProxies__*` list is not usable. Do not attach
other ingress to the task security group while relying on this. These entries
take precedence over `additional_env`. Without a certificate nothing is set.

### ACM with Route 53 (auto-provisioned)

If you own a Route 53 zone, the module can create and validate the certificate for you:

```hcl
domain_name     = "gis.example.com"
route53_zone_id = "Z1234567890ABC"
```

When both values are set, the module also creates a Route 53 alias `A` record for `domain_name` that points at the ALB, and `service_url` uses the custom HTTPS hostname. Disable that DNS record with `domain_alias_record_enabled = false` if another DNS provider owns the public zone; in that case, create the external DNS record yourself and keep using `service_url` as the custom HTTPS endpoint.

### Public base URL on your own domain

Honua runs on any domain you own; nothing in this module assumes a particular
DNS suffix. honua-server builds absolute links (publication URLs, OGC and STAC
self links, admin OIDC redirect URIs) only from `Public:BaseUrl` /
`PUBLIC_BASE_URL`, never from the request `Host`. Without it those links fall
back to a loopback origin, and admin OIDC refuses to start outside Development.

| Inputs | `Public__BaseUrl` the module sets |
|--------|-----------------------------------|
| `public_base_url` set | `public_base_url` (trailing `/` trimmed) |
| `domain_name` with an HTTPS listener (`alb_certificate_arn`, or `route53_zone_id`) | `https://<domain_name>` |
| Neither | nothing (links stay loopback; set one of the above for a public deployment) |

`public_base_url` must be an absolute `http`/`https` URL, optionally with a port
or path prefix (`https://example.org/gis`); the server ignores a bare host name,
so the module rejects one. Use it when clients reach the service through another
front door on your domain, such as a CDN. A `Public__BaseUrl` or
`PUBLIC_BASE_URL` already in `additional_env` is kept and wins (setting both
fails the `public_base_url_single_source` check). The value is set on the stable
and canary task definitions and reported by the `public_base_url` output. When
no `HostValidation__AllowedHosts__*` list is configured, honua-server also
accepts requests whose `Host` is this URL's host.

For public API hosts, allow HTTPS from the intended client CIDRs:

```hcl
allow_https_ingress_cidrs = ["0.0.0.0/0"]
```

## ALB canary rollout

The module can provision an optional canary ECS service and ALB target group. This is intended for weighted rollouts on AWS without moving rollout logic into Honua itself.

Because the canary and primary services run concurrently, canary rollouts require `deployment_mode = "MultiNode"`, Redis, and shared S3 file storage even when each service has only one task. The same contract applies when either `desired_count` or `max_capacity` is greater than one. A `SingleInstance` service uses ECS deployment percentages that stop the old task before starting its replacement so an ordinary update cannot temporarily create a second server task.

```hcl
canary_enabled           = true
canary_image             = "ghcr.io/honua-io/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
canary_desired_count     = 1
canary_weight_percentage = 0
```

Recommended rollout sequence:

1. Apply with `canary_enabled = true` and `canary_weight_percentage = 0`.
2. Verify the canary directly through the ALB header route:

   ```python
   from honua_sdk import HonuaClient

   with HonuaClient("https://<alb-url>") as client:
       print(client.readiness(extra_headers={"X-Honua-Canary": "always"}))
   ```

3. Increase `canary_weight_percentage` gradually in later applies.
4. Set `canary_weight_percentage = 0` again before tearing down the canary service.

When canary is enabled, the module also creates a header-based listener rule so operators can route requests directly to the canary target group without changing the default traffic split.

### Control-plane telemetry hints

The module does not provision Prometheus itself, but it exports recommended Honua control-plane metadata so rollback gates can be wired consistently:

- `control_plane_target_kind = "AwsEcs"`
- `control_plane_backend_name = "honua-gitops-aws-ecs"`, or `honua-aws-ecs-alb` when `deployment_safety` or `deploy_control_plane` is set
- `control_plane_telemetry_policy = "aws-alb-canary"` when canary is enabled, otherwise `honua-http`
- `control_plane_telemetry_prometheus_job = "honua"`
- `control_plane_telemetry_prometheus_canary_job = "honua-canary"` when canary is enabled

If your Prometheus scrape config uses different job names, override the corresponding `telemetry.prometheus.*` target parameters in Honua.

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `image` | Required | Container image. Pin to an immutable release tag or digest. AOT builds are recommended. |
| `domain_name` | `""` | Optional public hostname on any domain you own. With `route53_zone_id` the module issues the certificate and alias record; with `alb_certificate_arn` you manage both. Over HTTPS it becomes `service_url` and `Public__BaseUrl`. See [HTTPS](#https). |
| `public_base_url` | `""` | Public origin for server-built absolute links (`Public__BaseUrl`), for example `https://gis.example.com`. Empty uses `https://<domain_name>` on an HTTPS custom domain. See [Public base URL on your own domain](#public-base-url-on-your-own-domain). |
| `ai_provider_secret_arn` | `""` | Optional caller-owned Secrets Manager ARN for `HONUA_AI_PROVIDER_API_KEY`; the module never creates or exposes the value. |
| `ai_provider_secret_kms_key_arn` | `""` | Optional customer-managed KMS key ARN for the AI provider secret; grants decrypt only when the secret ARN is set. |
| `connection_encryption_master_key` | Required (nullable) | Fail-closed connection-key decision. Set `null` explicitly only for a new deployment; existing deployments must supply their current key as described below. |
| `task_cpu_architecture` | `X86_64` | Fargate CPU architecture. `X86_64` is release-certified; use `ARM64` only with an independently verified image. |
| `container_cpu` | 512 | Fargate CPU units (256/512/1024/2048/4096). |
| `container_memory` | 1024 | Fargate memory in MiB. |
| `desired_count` | 1 | Minimum number of tasks. Values greater than one require the safe MultiNode topology. |
| `max_capacity` | 1 | Maximum auto-scaling capacity. Values greater than one require the safe MultiNode topology. |
| `deployment_mode` | `SingleInstance` | Honua runtime mode. Set `MultiNode` for canary, HA, or auto-scaling. |
| `file_storage_provider` | `Local` | File storage backend. MultiNode requires `AwsS3`. |
| `file_storage_aws_s3_bucket_name` | `""` | Existing shared S3 bucket. Required with `AwsS3`; the module grants the ECS task role bucket access but does not create the bucket. |
| `file_storage_aws_s3_region` | AWS provider region | Region of the shared S3 bucket. |
| `file_storage_aws_s3_key_prefix` | `honua` | Optional object-key prefix within the shared bucket. |
| `canary_enabled` | false | Provision a secondary ECS service and ALB target group for canary rollouts. |
| `canary_image` | `""` | Optional image override for the canary service. Reuses `image` when empty. |
| `canary_desired_count` | 1 | Number of tasks in the canary ECS service. |
| `canary_weight_percentage` | 0 | Percentage of default ALB traffic routed to the canary target group. |
| `canary_header_name` | `X-Honua-Canary` | Header name that forces ALB routing to the canary target group. |
| `canary_header_value` | `always` | Header value that forces ALB routing to the canary target group. |
| `deploy_control_plane` | `null` | Opt-in in-service `honua-aws-ecs-alb` deploy target and CloudWatch telemetry connection in the stable and canary task environments. Requires `canary_enabled`; mutually exclusive with `deployment_safety`. See [Upgrade safety](#upgrade-safety). |
| `migration_safety` | `null` | Optional `Database__MigrationSafety__{ContractApplyPolicy,BackupCommand,Enforce}` for the inline startup migrations. See [Upgrade safety](#upgrade-safety). |
| `enable_postgis` | **false** | Enable PostGIS + PostGIS Raster on RDS. The Terraform runner must have a network path to the database. |
| `rds_deletion_protection` | **true** | Protect the managed RDS instance from deletion; disable in a separate apply before teardown. |
| `existing_db_endpoint` | `""` | Reuse an existing PostgreSQL endpoint (must be paired with `existing_db_connection_string`). |
| `existing_db_connection_string` | `""` | Reuse an existing PostgreSQL connection string (skips RDS provisioning and PostGIS local-exec). |
| `db_instance_class` | `db.t3.micro` | RDS instance class. Use `db.r6g.*` for production. |
| `db_multi_az` | false | Enable Multi-AZ failover. Recommended for production. |
| `db_require_ssl` | true | Append SSL requirements to the connection string. |
| `redis_enabled` | true | Provision ElastiCache Redis. |
| `redis_connection_string` | `""` | Reuse an existing Redis connection string instead of provisioning ElastiCache. |
| `redis_connection_cidrs` | `[]` | Trusted CIDRs for Redis egress when `redis_connection_string` points to an existing endpoint. |
| `redis_node_type` | `cache.t3.micro` | ElastiCache node type. |
| `alb_certificate_arn` | `""` | ACM certificate ARN. Falls back to HTTP if empty. |
| `waf_web_acl_arn` | `""` | WAFv2 Web ACL ARN for the ALB. |
| `enable_nat_gateway` | true | NAT gateways for private subnets (required for outbound). |
| `log_retention_days` | 365 | CloudWatch log retention. |
| `kms_key_arn` | `""` | Existing KMS key for logs/secrets. Creates one if empty. |
| `cors_allowed_origins` | `[]` | Browser origins rendered as `Cors__AllowedOrigins__<n>`. API-only cells need none. See [Browser origins (CORS)](#browser-origins-cors). |
| `operations_policy_rules` | `[]` | Ordered operation policy rules rendered as `Operations__Policy__Rules__<n>__<Field>`. Production denies every typed operation until a rule allows it. See [Operation policy rules](#operation-policy-rules). |
| `studio_end_user_authorization` | `false` | Let any authenticated principal use the Studio authoring API, subject to the server's per-resource Studio authorization; rendered as `Studio__EndUserAuthorization__Enabled=true` only when `true`. Off keeps the server default: only admins can author Studio content. |
| `import_background_job_threshold_bytes` | `null` | Upload size in bytes above which honua-server runs an import as a background job instead of inline; rendered as `Import__Limits__BackgroundJobThresholdBytes` on the primary and canary task definitions and wins over the same key in `additional_env`. `null` renders nothing and keeps the server default (100 MiB). Must be a whole number greater than 0. Output `import_background_job_threshold_bytes_rendered` reports what each task definition carries. |
| `licensing_mode` | `Disabled` | Licensing deployment mode declared as `Licensing__Mode`. `Disabled` is the 2026.1 contract: no license, no capacity metering, every entitlement active. Supplying `pro_license_secret_arn` implies `Enabled`. |
| `licensing_edition` | `Pro` | Edition declared as `Licensing__Edition` **only when** a license envelope is supplied. Ignored with no envelope. |
| `pro_license_secret_arn` | `""` | Caller-owned Secrets Manager ARN whose value is the signed license envelope JSON; injected as the ECS secret `Licensing__LicenseContent`. The module never creates, reads or deletes it. |
| `pro_license_secret_kms_key_arn` | `""` | Optional customer-managed KMS key ARN for the license secret; grants decrypt only when the license ARN is set. |
| `pro_license_key_id` | `honuademo2026q2` | Hyphen-free license keyId as relabeled in the envelope; builds the legal env var name `Licensing__TrustedKeys__<keyId>`. |
| `pro_license_trusted_public_key` | `""` | Ed25519 public key (`base64url:` prefixed) that verifies the license signature. Required when `pro_license_secret_arn` is set. |
| `request_secret_reference_allowed_environment_variables` | `[]` | Exact environment variable names a request may name as `env:NAME`. Rendered as `Security__RequestSecretReferences__AllowedEnvironmentVariables__<n>`. |
| `request_secret_reference_allowed_environment_variable_prefixes` | `[]` | Environment variable name prefixes a request may name as `env:NAME` (never matches a name containing `__`). Rendered as `Security__RequestSecretReferences__AllowedEnvironmentVariablePrefixes__<n>`. |
| `request_secret_reference_allowed_secret_reference_prefixes` | `[]` | Whole-reference prefixes for the other providers, including the provider segment, e.g. `aws:secretsmanager:honua/imports/`. Rendered as `Security__RequestSecretReferences__AllowedSecretReferencePrefixes__<n>`. |
| `request_secret_reference_secret_arns` | `[]` | Secrets Manager ARNs (trailing `*` allowed) that the ECS task role may read to resolve allowlisted `aws:secretsmanager:` references outside this module's own secrets. The allowlist alone does not authorize the read. |
| `request_secret_reference_kms_key_arns` | `[]` | Customer-managed KMS keys for those secrets, granted `kms:Decrypt` alongside them. |

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
request_secret_reference_allowed_secret_reference_prefixes     = ["aws:secretsmanager:honua/imports/"]
```

Entries are rendered in list order into the primary and canary container environments. For
the whole-reference list the provider (the text before the first colon) is
matched case-insensitively and the remainder is a case-sensitive prefix of the
reference, so an entry must have the same form as the references it is meant to
permit - a secret referenced by full ARN needs an ARN-form entry, one referenced by name a name-form entry. Keep entries as narrow as the deployment allows, and
give imports and connections their own variables or secret path rather than
listing the server's own credentials. Set the entries through these variables or
through `additional_env`, not both, so one source owns the indexes.

The server resolves an allowed `aws:secretsmanager:` reference with its own
runtime role, so a reference outside this module's own secrets also needs
`request_secret_reference_secret_arns` (and `request_secret_reference_kms_key_arns`
for customer-managed keys); keep them as narrow as the allowlist entries.

Server images that predate the setting ignore these variables, so they can be
set before upgrading; deployments that already rely on request-supplied
references should set matching entries before moving to an image that includes
the setting.

## Operation policy rules

The server image runs with its default environment, `Production`, whose
`appsettings.Production.json` enables `Operations:Policy` with
`DefaultDecision: Deny` ("Operations require an explicit production policy
rule."), and the server refuses to start in Production without an enabled,
fail-closed policy. Every typed operation, for example `service.publish`
(`honua_publish_service`), is therefore denied until the operator authors
rules. Set them with `operations_policy_rules`:

```hcl
operations_policy_rules = [
  # Admins publish services directly.
  { operation_id = "service.publish", role = "admin", decision = "Allow" },
  # Any other operation an admin starts waits for a second reviewer.
  {
    role          = "admin"
    decision      = "RequireApproval"
    reason        = "Production changes need a second reviewer."
    approval_lane = "control-plane"
  },
]
```

Rules are evaluated first-match-wins in list order; an operation no rule
matches keeps the `Deny` default. `operation_id` defaults to `"*"` (any
operation) and is otherwise matched exactly; `role` and `tier` are optional,
case-insensitive filters; `decision` is `Allow`, `RequireApproval`,
`DryRunFirst` or `Deny`; `reason` and `approval_lane` are optional (the lane is
used only by `RequireApproval`). Each rule renders as
`Operations__Policy__Rules__<n>__{OperationId,Role,Tier,Decision,Reason,ApprovalLane}`
on the primary and canary containers; unset fields render nothing, and the `operations_policy_environment`
output shows what was rendered. Set rules here or through `additional_env`, not
both, so one source owns the indexes.

## Browser origins (CORS)

Browser clients such as the Honua Console or Studio need their origin on the
server's CORS allowlist. Set them with the typed `cors_allowed_origins` input;
each entry is rendered in list order as `Cors__AllowedOrigins__<n>` on the
primary and canary containers:

```hcl
cors_allowed_origins = ["https://console.example.com"]
```

The default is `[]`, which renders nothing. API-only cells, called by SDKs, the
CLI or server-side clients, need no origins. Set the origins here or through
`additional_env`, not both, so one source owns the indexes.

## Licensing

The 2026.1 release ships with licensing **disabled** (operator ruling
2026-09-12; honua-server #4721). With no license inputs the module declares

- `Licensing__Mode = Disabled`

on the primary task definition and on the canary, declares no
`Licensing__Edition`, injects no license secret, and grants the execution role
no access to one.

The mode is declared rather than inferred. honua-server's own default is
`Licensing__Mode=Enabled`, which with no license source resolves to the
**Community** edition and gates editing, sync, streaming and geocoding; a
candidate deployed with no license inputs would then look
licensed-but-crippled instead of licensing-disabled. In `Disabled` mode the
server validates nothing, registers no capacity meter, activates every
`FeatureCatalog` entitlement, and `GET /api/v1/admin/license` answers
`mode: disabled`, `edition: Unlicensed-2026.1`, `validationState: Disabled`.

Set the mode with the typed `licensing_mode` input (`"Disabled"`, the default,
or `"Enabled"`), never through `additional_env`. Because the declared mode and
the deployed task definition must not disagree, `Licensing__*` keys (including
`Licensing__Mode`) are refused in `additional_env` / `canary_additional_env` and
fail the plan; use `licensing_mode` and the `pro_license_*` / `licensing_edition`
inputs below.

```hcl
module "honua" {
  # ...
  licensing_mode = "Disabled" # rendered as Licensing__Mode; not via additional_env
}
```

To supply a license (the 2026.2 path), point `pro_license_secret_arn` at an
existing Secrets Manager secret holding the signed envelope. The module injects
it as the ECS secret `Licensing__LicenseContent`, publishes
`Licensing__TrustedKeys__<pro_license_key_id>`, declares
`Licensing__Edition = licensing_edition`, and scopes the execution role's read
grant to that ARN (plus `pro_license_secret_kms_key_arn` when the secret uses a
customer-managed key). The plan fails if the verification public key is missing.

## Upgrade from the aliased connection key

Adding this required input is an intentionally breaking-but-safe module contract. Omission fails planning instead of silently replacing a deployed key. Earlier module versions used `admin_password` as `Security__ConnectionEncryption__MasterKey`. To avoid making existing encrypted connection records unreadable:

1. Before the first apply with this module version, set `connection_encryption_master_key` to the deployment's current connection encryption key. For deployments created by an earlier module version, that value is the current `admin_password`.
2. Apply and verify that the ECS task now references the separate connection-encryption secret while its value remains unchanged.
3. Rotate the key only with Honua's supported key rotation and re-encryption procedure. Do not rotate it by changing this Terraform input alone.

Brand-new deployments must set the input explicitly to `null`; Terraform then generates and stores an independent 32-character key. Never use `null` while upgrading an existing deployment.

## Outputs

See `outputs.tf` for ALB URL, ECS service names, canary routing headers, control-plane telemetry hints, RDS endpoint, secrets ARNs, and connection strings.

## After apply

1. Verify extensions: `psql $CONNECTION_STRING -c "SELECT PostGIS_Version(); SELECT extname FROM pg_extension WHERE extname IN ('postgis','postgis_raster');"`
2. Readiness check: call `HonuaClient("https://<alb-url>").readiness()` from the supported Python SDK.
3. If using OIDC, configure env vars per [Security Configuration](../../../../docs/devops/security.md)

## Deployment safety

The default ECS circuit breaker covers failed startup and requires a previous
completed deployment. SingleInstance has an unbounded interruption while the
replacement becomes ready. Both primary and canary task definitions are retained
with `skip_destroy`; after teardown, explicitly deregister obsolete revisions
only after their recovery window and evidence retention obligations end.

Set `deployment_safety` to wire the native ECS/ALB backend to an existing,
independently retained Honua controller. It requires MultiNode, Redis, shared S3,
a running stable/canary pair, digest-pinned images, a dedicated canary Prometheus
connection/job and an independently computed functional expectation. The module
installs a weighted traffic rule and grants the retained controller narrowly
scoped mutation/read permissions. It does not create a controller or telemetry
connection and reports the handoff as `configured-unverified`.

See [AWS deployment safety](../../../../docs/devops/aws-deployment-safety.md) for
runtime registration, finite limits, IAM/secret/storage validation and the
candidate-bound live recovery evidence required before claiming protection.

### Upgrade sequence with the migration task

With `migration_task = true` (see [Out-of-band migrations](#out-of-band-migrations)),
an image upgrade is four steps. Terraform never runs the migrator. Commands
come from the module's `migration_task` output, which
`examples/aws` exposes as `terraform output -json migration_task`:

1. **Register and run the migration task.** Set `migration_task_image` to the
   new digest and apply. Only the migration task definition changes; the
   serving services keep their image. Then run it:

   ```bash
   out="$(terraform output -json migration_task)"
   TASK_ARN="$(eval "$(jq -r .run_task_command <<<"$out")")"
   until eval "$(jq -r .wait_command <<<"$out")"; do :; done   # waiter gives up after 10 min; repeat
   ```

2. **Verify exit 0 and the summary.** `exit_code_command` prints the container
   exit code and the task's `stoppedReason`; `summary_command` prints the
   `honua.migrate-only/v1` line from the task's log stream:

   ```bash
   eval "$(jq -r .exit_code_command <<<"$out")"    # expect: 0  Essential container in task exited
   eval "$(jq -r .summary_command <<<"$out")"      # expect "outcome":"completed","exitCode":0
   ```

   Stop on anything but `0`. Nothing was applied by a refused run, and the
   serving services are untouched. Exit `5` (`contract-approval-required`):
   review `pendingScripts`, put the summary's `contractApproval.nonce` in
   `migration_task_additional_env = { HONUA_APPROVE_CONTRACT_MIGRATIONS = "<nonce>" }`,
   apply, run the task again, then remove the nonce. Exit `None` means the
   container never started (image pull, secrets or network): read
   `stoppedReason`. The other codes are listed under
   [Out-of-band migrations](#out-of-band-migrations).

3. **Roll the serving service.** Set `image` (and `canary_image` for a canary
   rollout) to the same digest and apply. The serving tasks start with
   `HONUA_SKIP_MIGRATIONS=true`, verify the journal against their binary and
   never migrate. The ECS deployment circuit breaker rolls back a task
   definition whose tasks fail to start. With a canary, the migrator runs the
   canary image and environment, so step 1 targets the candidate.

4. **Verify preflight.** `GET /api/v1/admin/deploy/preflight` must report no
   pending migrations and readiness on every task before you shift traffic or
   promote.

The circuit breaker can only roll the service back to the previous task
definition. It cannot downgrade the schema the migrator applied, and serving
tasks with `HONUA_SKIP_MIGRATIONS=true` that include the schema-reader guard
refuse to start on any journal entry their image does not ship
(`schema_reader_incompatible`): they never accept the forward-compatibility
declarations that images at schema 135 and later record
(honua-io/honua-server#6478). Rolling the image back across an applied
migration on this path therefore needs a database restore or a roll forward;
take the backup before step 1. Only tasks that migrate inline
(`migration_task = false`) at schema 135 or later accept a verified
expand-only declaration on rollback. Images at schema 134 and earlier that
include the schema-reader guard, journals written before 135, and contract or
reader-incompatible scripts still refuse. An image without the guard does not
refuse; see [Rollback target eligibility](#rollback-target-eligibility).


### Rollback target eligibility

Image rollback never reverses migrations. Before you roll an ECS service back to an earlier task definition or image, check that
the target image can protect itself against the schema it will find (see
[Rollback target eligibility](https://github.com/honua-io/honua-server/blob/trunk/docs/guides/deploy/upgrade-and-rollback.md#rollback-target-eligibility)):

- **Roll back only to images that include the schema-reader guard.** Across
  additive (expand-only) migrations that means schema 135 or later; those
  images verify the forward-compatibility declarations a newer server
  recorded.
- **Never roll back across a contract-phase migration without a restore.** This
  includes scripts marked `-- honua:reader-incompatible`. Restore the
  pre-upgrade backup that matches the target revision instead.
- **`honua-2026.1` is unguarded and not a safe rollback target across any
  migration** ([honua-io/honua-server#6484](https://github.com/honua-io/honua-server/issues/6484)).
  Its server image (honua-server `f897700`, schema 106) predates the
  schema-reader guard: on a newer database it starts and serves without
  refusing, even across contract-phase migrations. The only safe path back to
  2026.1 is to restore the backup taken before the upgrade.
- **Pin rollback targets by digest.** The tag named in the 2026.1 release notes
  has since moved to a rebuild
  ([honua-io/honua-release#776](https://github.com/honua-io/honua-release/issues/776)).

## Upgrade safety

Honua's upgrade contract is expand/contract: a release that only adds schema
can roll out while the previous version still serves, and a release that
narrows schema must wait until no older reader remains. Read
[Upgrade and roll back](https://github.com/honua-io/honua-server/blob/trunk/docs/guides/deploy/upgrade-and-rollback.md)
first. This module wires migration safety, the in-service deploy control plane
and an opt-in out-of-band migration task.

### Migration safety

By default ECS tasks apply pending migrations at startup, behind a PostgreSQL
advisory lock. `migration_safety` renders `Database:MigrationSafety` on the
stable and canary task definitions (and on the migration task when
`migration_task = true`), and the typed values win over `additional_env`:

```hcl
migration_safety = {
  contract_apply_policy = "Gate"                        # default; or "Auto"
  backup_command        = "/opt/honua/pre-migrate.sh"   # optional
}
```

With `Gate` (also the server default), a pending reviewed contract-phase
migration on an existing database stops startup and prints a one-shot nonce.
Supply it as `HONUA_APPROVE_CONTRACT_MIGRATIONS` in `canary_additional_env` (or
`additional_env`) for that one apply, then remove it. `backup_command` runs
inside the server container immediately before contract-phase scripts apply.
A non-zero exit aborts the run. The stock image is not documented to ship
`pg_dump`, so point it at a tool your image provides. The value is a plain
environment variable: keep credentials out of it.

### In-service deploy control plane

`deploy_control_plane` registers this cell's canonical `honua-aws-ecs-alb`
deploy target and a CloudWatch telemetry connection in the task environment,
so the server's admin deploy API can plan, gate, promote and roll back an ECS
canary without a separate controller:

```hcl
canary_enabled       = true
deployment_mode      = "MultiNode"   # plus Redis and shared S3, as for any canary
deploy_control_plane = {
  canary_weight_percentage = 10      # null: direct cutover
}
```

It renders `ControlPlane__DeployTargets__0__*`, with the dotted parameters as
`ParameterEntries`, and `ControlPlane__TelemetryConnections__0__*`
(`Provider=cloudwatch`). It installs the same stable=100/candidate=0 weighted
rule at priority 50000 as `deployment_safety`, whose actions Terraform ignores
afterwards. The task role may update the canary service, modify that rule,
describe the stable service and read CloudWatch metrics. The default telemetry
queries read `RequestCount` (the sample floor) and p95 `TargetResponseTime`
for the canary target group only, so the stable service's traffic cannot mask
the candidate. `RequiresApproval` defaults to `true`.

The error-rate signal is off unless you set `error_rate_query`. ALB does not
publish `HTTPCode_Target_5XX_Count` for a period with no 5XX responses. The
server's CloudWatch reader evaluates a single expression and treats a missing
series as no evidence, so a synthesized error ratio would hold a healthy
rollout and then roll it back (honua-io/honua-server#6474). The `deploy_control_plane.alb_metric_dimensions`
output gives the dimension values for writing your own expression.

This topology is weaker than `deployment_safety`. Every MultiNode task
reconciles active deploy operations under a lease, so the catalog, connection
and permissions go to the stable and canary tasks alike, and a candidate can
act on its own rollout. Prefer `deployment_safety` with an external retained
controller where you have one; the two are mutually exclusive. Do not apply a
new infrastructure or candidate change while an operation owns the target: an
apply resets the canary service to the Terraform-registered task definition.
The output reports `configured-unverified`. Mock tests prove neither the
CloudWatch expressions nor a live rollback.

### Out-of-band migrations

`migration_task = true` (default `false`) moves migrations out of band using
the server's migrate-only mode (honua-io/honua-server#6479). It requires a
honua-server image at or after the first release that ships
`HONUA_MIGRATE_ONLY`; today that is the next release after 2026.1 (the 2026.1
server image does not have it). An older image ignores `HONUA_MIGRATE_ONLY`,
starts serving and never exits.

```hcl
migration_task       = true
migration_task_image = "ghcr.io/honua-io/honua-server@sha256:<new digest>"  # optional; see the upgrade sequence
```

- The module registers a one-shot task definition `<name>-migrate-task`
  (`skip_destroy`, like the serving definitions). It has the same image
  (`migration_task_image`, else the canary image when `canary_enabled`, else
  `image`), Secrets Manager secrets, execution and task roles, CPU and memory,
  architecture and log group as the serving task. Its environment is the
  serving environment (the canary's when `canary_enabled`), including
  `migration_safety`, without `HONUA_SKIP_MIGRATIONS`, plus
  `migration_task_additional_env` and `HONUA_MIGRATE_ONLY=true`. It has no
  port mapping or health check, and logs under the `honua-migrate` stream
  prefix.
- The stable and canary task definitions get `HONUA_SKIP_MIGRATIONS=true`. The
  serving tasks verify the journal and never migrate.
- `output.migration_task` gives the task definition, cluster, launch type,
  subnets, security groups and public-IP setting. It also gives the exact
  `run_task_command`, `wait_command` (`aws ecs wait tasks-stopped`),
  `exit_code_command` (`aws ecs describe-tasks`, container exit code plus
  `stoppedReason`) and `summary_command` (CloudWatch Logs filter for the
  `honua.migrate-only/v1` line). The `wait_command`, `exit_code_command` and
  `summary_command` read the task ARN from `$TASK_ARN`.
- The plan fails when `HONUA_MIGRATE_ONLY` appears in `additional_env`,
  `canary_additional_env` or `migration_task_additional_env`, when
  `HONUA_SKIP_MIGRATIONS` appears in `additional_env` or `canary_additional_env`
  while `migration_task` is on, and when `migration_task_image` or
  `migration_task_additional_env` is set without `migration_task`.

The migrator's exit codes are `0` completed, `2` invalid configuration, `3`
database unreachable, `4` PostGIS missing or unsupported, `5` contract approval
needed, `6` unannotated contract migration, `7` backup command failed, `8`
schema newer than this image, `9` migration lock timeout, `10` migration
failed and `11` cancelled (SIGTERM). The task's `stopTimeout` is 120 seconds, so
a stopped run reaches its next safe point. See
[Run migrations out of band](https://github.com/honua-io/honua-server/blob/trunk/docs/guides/deploy/upgrade-and-rollback.md#run-migrations-out-of-band)
for the summary fields and what to do for each code. `backup_command` runs
inside the migrator container. The run sequence is under
[Upgrade sequence with the migration task](#upgrade-sequence-with-the-migration-task).

With `migration_task = false` nothing changes: no migration task, no
`HONUA_SKIP_MIGRATIONS`, and serving tasks keep migrating inline under
`migration_safety`.

## Certification inputs

Workload images must be digest-pinned (`registry/repository@sha256:<64 hex>`).
Bedrock uses the workload IAM role and configures `StudioAiProxy` as well as
`WorkflowGeneration`. See [AWS certification inputs](../../../../docs/devops/aws-certification-inputs.md)
for N-1/N pins, custom-code worker requirements, OIDC roles and live evidence limits.

## Redis operation key-ring certificate

Every Redis-backed Production task, including a caller-owned Redis endpoint,
requires `operation_key_ring_certificate_secret_arn`. Omission fails planning
with an actionable error; Redis-off neither requires nor injects a certificate.
The example stack forwards the same input and defaults to an empty ARN so a
new disposable cell fails closed until protected material is supplied. It does
not generate a private key in Terraform state or use a shared test key.

The ARN must identify an existing operator-owned Secrets Manager secret. Its
value must be standard base64 PKCS#12 with a private key, or a JSON bundle
`{"pkcs12":"<base64>","password":"<PKCS#12 password>"}`. Retain the same
certificate for the lifetime of the Redis key ring and across task replacements
and stable/canary slots; a new certificate cannot decrypt the old ring. Store
and rotate it separately from Redis. Never put the bundle, its password, or a
private key into tfvars, `additional_env`, or `canary_additional_env`.

```hcl
redis_enabled = true
operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
```

ECS resolves the bundle as the secret
`Operations__SecretChannel__KeyRingCertificatePkcs12` in both task definitions.
The existing server boundary writes a unique private temporary file (Unix mode
0600) and loads its certificate; the Redis data-protection ring still requires
certificate encryption. Use an image containing that materialization boundary.
No secret value is read or written by this module.

The module grants the execution role read access to exactly this secret while
Redis is configured. For a customer-managed encryption key, supply
`operation_key_ring_certificate_secret_kms_key_arn`; the module grants
`kms:Decrypt` and `kms:DescribeKey` on that exact key. The operator must also
ensure the secret resource policy and KMS key policy permit this role. A valid ARN alone
does not prove the secret exists, is accessible, or contains valid PKCS#12.
Terraform checks the input contract without reading the private key; ECS and the
server reject missing/inaccessible/invalid content before a serving target is
ready. Validate the operator's bundle privately before its separate provisioning
operation. No live IAM or secret provisioning is included here.

## Audit hash-chain key

The server hash-chains every audit row. With `AuditLog:ChainVerification:Key`
set to a base64 key of at least 32 decoded bytes, each row's hash is an
HMAC-SHA256 under that key, which is held outside the database. Without it
audit rows are still written and requests are served, but scheduled chain
verification never succeeds and the `audit-chain-integrity` health check
reports Unhealthy (the server logs `Audit hash-chain integrity FAILED ...
audit chain key is not configured`). The key is therefore recommended rather
than required: an empty `audit_chain_key_secret_arn` produces a plan-time
warning (`check.audit_chain_key_configured`), not an error.

Supply the ARN of an operator-owned Secrets Manager secret whose value is the
base64 key (for example `openssl rand -base64 32`), plus
`audit_chain_key_secret_kms_key_arn` for a customer-managed key. Only the ARN
enters Terraform. Keep the same key for the deployment's lifetime and give it
to every audit writer. Set it at first install. On a deployment that already
has audit rows, follow the server's phased activation (roll out with the key
unset, then stop every writer, set the key everywhere and restart): a writer
without the key appending after the first keyed row permanently breaks
verification. The module rejects `AuditLog__ChainVerification__Key` in
`additional_env`.

ECS resolves the secret as `AuditLog__ChainVerification__Key` in both the
stable and canary task definitions, and the module grants the execution role
read on exactly that secret (and `kms:Decrypt`/`kms:DescribeKey` on a supplied
customer-managed key).

## Failed-cell diagnostics

Capture evidence **before teardown**: ECS stopped-task history is short-lived
and teardown deletes the cell's CloudWatch log group. The read-only collector
retains service events, stopped/running task descriptions (including stop
reason, container reason and exit code), and every container log stream. Run it
for both slots when canary is enabled:

```bash
python3 infrastructure/terraform/modules/aws-ecs/scripts/capture-task-diagnostics.py \
  --region us-east-1 --cluster '<ecs_cluster_name>' \
  --service '<ecs_service_name>' --service '<canary_ecs_service_name>' \
  --log-group '/honua/<name_prefix>-<environment>' \
  --output-dir '<new-private-evidence-directory>'
```

Omit the second `--service` for a single-slot cell. Upload that directory as a
restricted certification artifact on failure, even if the collector exits 1.
`collection.json` records incomplete reads; collection continues after read
errors so available logs survive. The collector reads no secret values or
task-definition environment. Its output can contain application/operator data
and is created with private permissions. It requires existing read permissions
for ECS services/tasks and CloudWatch logs; it grants none. Collection and
artifact upload must run before the runner's teardown/reaper, preserving the
original failure verdict and the existing fail-closed cleanup behavior.

Offline Terraform tests establish the injection/refusal contract, and mocked
collector tests establish evidence retention under task exit and read failures.
They do not prove an exact-candidate AWS cell healthy. The historical ALB 503s
had no stopped-task logs, so their exact task exit cause remains unverified.
Release runner wiring, protected disposable-cell material/authorization, and a
live Redis-on cell with healthy targets, 200 live/ready and the full protocol
sweep remain required before closing #213.


### Optional static JWT issuer

`oidc_static_jwt` is an opt-in object containing `issuer` (HTTPS), `audience`,
`signing_key_secret_arn` and optional `signing_key_kms_key_arn`. The secret must
already exist and contain a signing key of at least 32 UTF-8 bytes. Create and
rotate its value outside Terraform: the module neither reads that value nor
manages a secret version. Omit the object to preserve the existing authentication
configuration. Configure Studio end-user authorization separately when needed.

ECS injects the secret through its task execution role. Lambda receives an
`aws:secretsmanager:` reference and requires a server version containing
[honua-server5980](https://github.com/honua-io/honua-server/issues/5980); older
servers cannot use that reference as a static signing key. Only the API Lambda
receives the issuer and signing-secret permission; event functions do not.
Issuer, audience, signature and lifetime validation remain enabled. A static
signing key is captured at process startup, so restart the deployment after
rotation. The Lambda environment remains subject to its unchanged 4096-byte
limit; do not remove security settings or raise that ceiling to fit a fixture.

Set optional `signing_key_secret_version_id` to bind the version the runtime actually
consumes. ECS renders the [version-specific secret reference](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html);
Lambda uses the server resolver's `?versionId=` option. IAM permissions remain scoped
to the bare secret ARN. An omitted version retains normal current-version behavior.

## Declared platform release identity

`platform_release` optionally passes the signed release's `version`, digest-pinned
`serving_artifact_reference`, and optional `workers` (each with
`artifact_reference` and optional `runtime_profile`) to the server's
`ControlPlane:PlatformRelease` configuration. Null is the default and preserves
existing environment configuration. Supplying the typed object replaces raw
settings in that configuration subtree, including stale worker entries.
This declares identity; it does not verify a lock signature or certify a deployment.
The release runner must verify the signed lock and the actual serving image.

`canary_platform_release` defaults to `platform_release`. Set it to the candidate
identity while the primary retains the prior identity during a staged update.
Changing this input updates task configuration; it does not promote ALB traffic.

## Model transcript signing

`transcript_signing` defaults to `null`. To enable it, supply an approved public
key ID and existing signing-secret ARN, with optional immutable version ID and
exact KMS key ARN. No private value is read by Terraform. See the
[operator signing guide](../../../../docs/devops/aws-transcript-signing.md) for
runtime IAM, public-manifest binding, rotation and the Lambda server dependency.
