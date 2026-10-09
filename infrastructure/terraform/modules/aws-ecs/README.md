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
  image          = "123456789012.dkr.ecr.us-west-2.amazonaws.com/honua-server:v1.2.3-ecs-aot"
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
  image            = "123456789012.dkr.ecr.us-west-2.amazonaws.com/honua-server:v1.2.3-ecs-aot"  # Pin to a release ECS AOT tag in ECR
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
  canary_image             = "123456789012.dkr.ecr.us-west-2.amazonaws.com/honua-server:v1.2.4-ecs-aot"
  canary_desired_count     = 1
  canary_weight_percentage = 0

  # Security
  waf_web_acl_arn = var.waf_acl_arn  # Optional WAFv2

  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI       = "true"
    HONUA_OBSERVABILITY  = "true"
    HONUA_OPENTELEMETRY  = "true"
    Public__BaseUrl      = "https://gis.example.com"
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

### ACM with Route 53 (auto-provisioned)

If you own a Route 53 zone, the module can create and validate the certificate for you:

```hcl
domain_name     = "gis.example.com"
route53_zone_id = "Z1234567890ABC"
```

When both values are set, the module also creates a Route 53 alias `A` record for `domain_name` that points at the ALB, and `service_url` uses the custom HTTPS hostname. Disable that DNS record with `domain_alias_record_enabled = false` if another DNS provider owns the public zone; in that case, create the external DNS record yourself and keep using `service_url` as the custom HTTPS endpoint.

For public API hosts, allow HTTPS from the intended client CIDRs:

```hcl
allow_https_ingress_cidrs = ["0.0.0.0/0"]
```

## ALB canary rollout

The module can provision an optional canary ECS service and ALB target group. This is intended for weighted rollouts on AWS without moving rollout logic into Honua itself.

Because the canary and primary services run concurrently, canary rollouts require `deployment_mode = "MultiNode"`, Redis, and shared S3 file storage even when each service has only one task. The same contract applies when either `desired_count` or `max_capacity` is greater than one. A `SingleInstance` service uses ECS deployment percentages that stop the old task before starting its replacement so an ordinary update cannot temporarily create a second server task.

```hcl
canary_enabled           = true
canary_image             = "ghcr.io/honua-io/honua-server:v1.2.4-aot"
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
- `control_plane_backend_name = "honua-gitops-aws-ecs"`
- `control_plane_telemetry_policy = "aws-alb-canary"` when canary is enabled, otherwise `honua-http`
- `control_plane_telemetry_prometheus_job = "honua"`
- `control_plane_telemetry_prometheus_canary_job = "honua-canary"` when canary is enabled

If your Prometheus scrape config uses different job names, override the corresponding `telemetry.prometheus.*` target parameters in Honua.

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `image` | Required | Container image. Pin to an immutable release tag or digest. AOT builds are recommended. |
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
