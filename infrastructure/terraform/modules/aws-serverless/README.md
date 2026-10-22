# AWS Lambda (Serverless) Module

Deploys Honua Server to AWS Lambda (container image) behind an API Gateway HTTP API, with RDS PostgreSQL and optional ElastiCache Redis.

The opt-in migration function has its own role. Its database read is pinned to
one secret version; ENI creation is limited to this deployment's subnets and
security group. ENI maintenance permissions cover interfaces in the deployment's
VPC and region; they are not restricted by per-function ENI tags. The role
configures an explicit `lambda:SourceFunctionArn` deny for calls from migration
code, while retaining Lambda service permissions for VPC lifecycle management.
The deny uses the unqualified function ARN, as required by AWS's
[source-function condition-key contract](https://docs.aws.amazon.com/lambda/latest/dg/permissions-source-function-arn.html).
These tests check the policy document; actual denied EC2 calls from a running
migration function have not been exercised. Cloud execution remains unqualified.
Migration tracing follows `enable_xray_tracing` and grants only regional trace
writer APIs when enabled.

The immutable migration function configuration also pins
`HONUA_MIGRATION_MANIFEST_SHA256` to the supplied packaged artifact manifest.
The matching Server profile must verify its actual SQL and contract-template
fingerprint before resolving the database secret or executing migrations.
Terraform independently checks the returned manifest again before serving
updates. Use matching qualified Server/IaC artifacts; this remains an opt-in
preview and is not a live-cloud qualification claim.

The migration function expects a `honua.lambda-migration-run/v1` receipt that
honua-server does not produce yet. honua-server#6479 shipped migrate-only mode
for container tasks and Jobs only. That mode refuses to run inside AWS Lambda
and prints `honua.migrate-only/v1`, not this receipt. Until the server ships
the Lambda receipt, the migration function stays preview and unqualified, and
the ECS module's `migration_task` is the supported out-of-band migrator.

Migration logs and environment configuration use AWS's default encryption at
rest. This preview profile does not provision customer-managed keys for either.
The function has no asynchronous trigger: Terraform invokes its numeric version
synchronously and blocks serving deployment unless the receipt verifies. Lambda
code signing does not support container images; deployment requires an immutable
image digest and the matching packaged migration manifest. See AWS's
[VPC execution-role guidance](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html)
and [container-image signing limitation](https://docs.aws.amazon.com/lambda/latest/dg/configuration-codesigning-create.html).

## Pin to a release

For a versioned, external pin, consume this module by Git source at a SemVer tag
instead of a relative path. (The Honua repos are ELv2-licensed, so the public
Terraform Registry is not used — see
[`docs/module-versioning.md`](../../../../docs/module-versioning.md).)

```hcl
module "honua" {
  source = "git::https://github.com/honua-io/honua-iac.git//infrastructure/terraform/modules/aws-serverless?ref=v0.1.0"
  # ...inputs below...
}
```

Bump `?ref=` to move to a newer release and run `terraform init -upgrade`.

## Quick start

```hcl
module "honua" {
  source = "../../modules/aws-serverless"

  environment    = "dev"
  image          = var.honua_image_uri   # Must be an ECR image URI
  admin_password = var.honua_admin_password
  enable_postgis = true  # Required — Honua needs PostGIS + PostGIS Raster

  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI       = "true"
  }
}
```

## Prerequisites

- **ECR image**: Lambda container images must be stored in ECR. Push the Honua Lambda image (`*-lambda-aot` preferred; `*-lambda` debug fallback) to your ECR repository before applying.
- **PostGIS + PostGIS Raster**: Set `enable_postgis = true` (requires `psql` on the apply machine with network access to RDS). For controlled temporary access from CI/local runners, use `db_additional_ingress_cidrs`.
- **Migrations**: `skip_migrations` defaults to `true` for serving functions. Schema initialization must complete before traffic. The optional `migration_image` preview uses an isolated, version-pinned function and gates serving deployment on its verified receipt; it requires a qualified matching image and `migration_packaged_manifest_sha256`. A failed receipt requires the [scoped recovery procedure](../../examples/aws-serverless/README.md#migrations-on-the-serverless-root). Reused VPCs get a Secrets Manager endpoint by default because this module cannot infer their NAT routing. No matching public migration artifact or real AWS run is qualified yet. HTTP readiness alone is not a migration receipt.

## Production example

```hcl
module "honua" {
  source = "../../modules/aws-serverless"

  environment = "prod"
  name_prefix = "honua"

  # Lambda
  image                                 = var.honua_image_uri
  lambda_memory_size                    = 2048       # MB
  lambda_timeout_seconds                = 29         # Must be < API Gateway's 30s limit
  lambda_ephemeral_storage_mb           = 1024
  lambda_reserved_concurrent_executions = 100

  # Database
  admin_password       = var.honua_admin_password
  db_instance_class    = "db.r6g.large"
  db_allocated_storage = 100
  db_multi_az          = true
  db_require_ssl       = true
  enable_postgis       = true
  skip_migrations      = true   # Run migrations out-of-band

  # Redis
  redis_enabled            = true
  redis_node_type          = "cache.r6g.large"
  redis_num_cache_clusters = 2
  # Required with Redis; see "Redis operation key-ring certificate".
  operation_key_ring_certificate_secret_arn = var.operation_key_ring_certificate_secret_arn

  # Networking
  enable_nat_gateway = true  # Required for outbound access (OIDC, external APIs)

  # Custom domain on any domain you own; also sets Public__BaseUrl.
  domain_name     = "gis.example.com"
  route53_zone_id = var.route53_zone_id

  additional_env = {
    HONUA_OBSERVABILITY = "true"
  }
}
```

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `image` | *(required)* | ECR image URI. Must implement Lambda Runtime API. |
| `image_repository_policy_mode` | `"owned"` | `owned` installs (and on destroy deletes) the Lambda retrieval policy on `image`'s repository, which must be in the deploying account and region. `reuse` consumes a shared repository whose owner already authorizes Lambda retrieval and never reads, writes or deletes its policy. See [Image repository policy](#image-repository-policy). |
| `lambda_memory_size` | 1024 | Lambda memory in MB (128–10240). |
| `lambda_timeout_seconds` | 30 | Keep at or below 30 (API Gateway limit). |
| `lambda_architectures` | `["x86_64"]` | `x86_64` by default, matching the 2026.1 platform manifest (`awsLambdaArchitecture: x86_64`). Use `arm64` only with an independently verified arm64 image. |
| `cors_allowed_origins` | `[]` | Browser origins (Console/Studio) rendered as `Cors__AllowedOrigins__<n>`. honua-server is the only CORS source, as on ECS: API Gateway has no CORS configuration, so preflights reach the server. See [CORS](#cors). Empty or `null` configures no CORS; API-only cells need none. |
| `operations_policy_rules` | `[]` | Ordered operation policy rules rendered as `Operations__Policy__Rules__<n>__<Field>`. Production denies every typed operation until a rule allows it. See [Operation policy rules](#operation-policy-rules). |
| `studio_end_user_authorization` | `false` | Let any authenticated principal use the Studio authoring API, subject to the server's per-resource Studio authorization; rendered as `Studio__EndUserAuthorization__Enabled=true` only when `true`. Off keeps the server default: only admins can author Studio content. |
| `import_background_job_threshold_bytes` | `null` | Upload size in bytes above which honua-server runs an import as a background job instead of inline; rendered as `Import__Limits__BackgroundJobThresholdBytes` on the API Lambda and the GP Batch job definitions (like the [database pool caps](#database-connection-budget); the control-plane event functions serve no uploads and leave it out) and wins over the same key in `additional_env`. `null` renders nothing and keeps the server default (100 MiB). Must be a whole number greater than 0. Adds about 57 bytes to each Lambda environment (see [Lambda environment budget](#lambda-environment-budget)). Output `import_background_job_threshold_bytes_rendered` reports what each process carries. |
| `file_storage_provider` | `Local` | Honua file storage provider: `Local` (the server default; renders nothing) or `AwsS3`. `AwsS3` renders `FileStorage__*` on the API Lambda, the control-plane event functions and every GP Batch job-definition tier and grants their roles access to the bucket, so a background import the API Lambda accepts can run on GP Batch. See [Shared file storage](#shared-file-storage). Same input as `modules/aws-ecs`. |
| `file_storage_aws_s3_bucket_name` | `""` | Existing S3 bucket for shared file storage (`FileStorage__AwsS3__BucketName`). Required with `AwsS3`; the module grants access but does not create the bucket. |
| `file_storage_aws_s3_region` | module region | Region of the shared bucket (`FileStorage__AwsS3__Region`, which the server requires). Empty renders the AWS provider region. |
| `file_storage_aws_s3_key_prefix` | `honua` | Object-key prefix within the bucket (`FileStorage__AwsS3__KeyPrefix`); the object grants are scoped to `<bucket>/<prefix>/*`. Empty renders no prefix and grants the whole bucket. |
| `domain_name` | `""` | Optional custom API hostname on any domain you own (for example `gis.example.com`; any TLD, including punycode `xn--` names). With `route53_zone_id`, creates the certificate, API Gateway custom domain, mapping and alias described in [Custom domain](#custom-domain), and sets `Public__BaseUrl`. Same input as `modules/aws-ecs`. |
| `public_base_url` | `""` | Public origin for server-built absolute links (`Public__BaseUrl`), for example `https://gis.example.com`. Empty uses `https://<domain_name>` when the custom domain is configured. See [Custom domain](#custom-domain). |
| `route53_zone_id` | `""` | Route53 hosted zone that owns `domain_name`, for certificate validation and the alias record. Set together with `domain_name`; one without the other creates nothing and fails the `custom_domain_inputs` check. |
| `lambda_alias_name` | `live` | Stable alias used for API Gateway traffic and control-plane rollback. |
| `lambda_alias_version` | `null` | Optional published version to pin the stable alias to; defaults to the version published by the current apply. |
| `lambda_alias_routing` | `null` | Optional `{ additional_version, weight }` weighted split on the live alias (`routing_config.additional_version_weights`). See [Weighted alias canaries](#weighted-alias-canaries). |
| `lambda_deploy_canary` | `null` | Optional control-plane canary: canary weight and telemetry gate parameters on the deploy target plus a CloudWatch telemetry connection. See [Weighted alias canaries](#weighted-alias-canaries). |
| `enable_postgis` | **false** | Enable PostGIS + PostGIS Raster on RDS. **Set to true.** |
| `existing_db_endpoint` | `""` | Reuse an existing PostgreSQL endpoint (must be paired with `existing_db_connection_string`). |
| `existing_db_port` | `5432` | TCP port of the reused database. Set it to the port in the pinned `existing_db_connection_string`; Lambda database egress and the automatic migration locator hash use this port. The module-managed database remains on 5432. |
| `existing_db_connection_string` | `""` | Reuse an existing PostgreSQL connection string (skips RDS provisioning and PostGIS local-exec). |
| `skip_migrations` | true | Skip auto-migrations. Run them out-of-band for serverless. |
| `db_instance_class` | `db.t3.micro` | RDS instance class. |
| `lambda_db_max_pool_size` / `control_plane_db_max_pool_size` / `gp_batch_db_max_pool_size` | `8` / `2` / `4` | PostgreSQL pool cap per warm API Lambda instance, per warm control-plane Lambda instance and per running GP Batch job. See [Database connection budget](#database-connection-budget). |
| `db_connection_idle_lifetime_seconds` | `60` | Idle pooled connection lifetime (10-3600). |
| `enable_rds_proxy` | `false` | Put RDS Proxy in front of the module-managed PostgreSQL and route the Lambda functions and GP Batch jobs through it; migrations keep the direct endpoint. See [Database connection budget](#database-connection-budget). |
| `rds_proxy_max_connections_percent` / `rds_proxy_max_idle_connections_percent` | `90` / `50` | Proxy ceiling and idle connections, as a percentage of the instance's `max_connections`. |
| `rds_proxy_connection_borrow_timeout_seconds` / `rds_proxy_idle_client_timeout_seconds` | `120` / `600` | How long a client waits for a connection at the ceiling, and how long an idle client connection (a frozen Lambda environment's) is kept. |
| `rds_proxy_set_role_session_defaults` | `null` | With the proxy: run `ALTER ROLE <db_username> SET` for the server's session timeouts during apply (psql, like `enable_postgis`). Null follows `enable_postgis`. See [Database connection budget](#database-connection-budget), Pinning. |
| `db_multi_az` | false | Enable Multi-AZ failover. |
| `redis_enabled` | true | Provision ElastiCache Redis. |
| `redis_connection_string` | `""` | Reuse an existing Redis connection string instead of provisioning ElastiCache. |
| `redis_connection_cidrs` | `[]` | Trusted CIDRs for Redis egress when `redis_connection_string` points to an existing endpoint. |
| `operation_key_ring_certificate_secret_arn` | `""` | **Required whenever Redis is configured.** ARN of an operator-owned Secrets Manager PKCS#12 bundle; see [Redis operation key-ring certificate](#redis-operation-key-ring-certificate). |
| `operation_key_ring_certificate_secret_kms_key_arn` | `""` | Customer-managed KMS key encrypting that secret; empty for the AWS-managed key. |
| `audit_chain_key_secret_arn` | `""` | **Recommended.** ARN of an operator-owned Secrets Manager secret holding the base64 audit hash-chain key; see [Audit hash-chain key](#audit-hash-chain-key). |
| `audit_chain_key_secret_kms_key_arn` | `""` | Customer-managed KMS key encrypting that secret; empty for the AWS-managed key. |
| `enable_nat_gateway` | true | NAT gateways for outbound access. Required for OIDC. |
| `enable_dashboard` | false | Create a CloudWatch dashboard (Lambda duration/errors/throttles/concurrency, API Gateway, cold-start, and custom Honua metrics). |
| `enable_xray_tracing` | false | Enable Lambda X-Ray active tracing, grant least-privilege `xray:PutTraceSegments`/sampling reads, and set the app-side `Tracing__XRay__Enabled` flag. |
| `enable_lambda_insights` | false | Attach the CloudWatch Lambda Insights managed policy and add the Insights widgets (the Insights extension layer must be present in the image). |
| `honua_metrics_namespace` | `Honua/Serverless` | CloudWatch namespace the custom Honua metrics (cold-start, init duration) are published to via an ADOT/EMF collector; used by the dashboard's custom widgets. |
| `licensing_mode` | `Disabled` | Licensing deployment mode declared as `Licensing__Mode`. `Disabled` is the 2026.1 contract: no license, no capacity metering, every entitlement active. `Enabled` loads and validates a license. Supplying one via `enable_pro_license` implies `Enabled`. |
| `enable_pro_license` | false | Deliver a signed Pro license to the Lambda via Secrets Manager and set `Licensing__Mode=Enabled`. When off the deployment runs with licensing **disabled** (all entitlements active), not Community. |
| `pro_license_content` | `""` | Signed Pro license envelope JSON (relabeled hyphen-free keyId). Stored in `<name>/license-pro` and referenced by `Licensing__LicenseContentSecretRef`. Required when `enable_pro_license`. |
| `pro_license_key_id` | `honuademo2026q2` | Hyphen-free license keyId as relabeled in the envelope; used to build the legal env var name `Licensing__TrustedKeys__<keyId>`. |
| `pro_license_trusted_public_key` | `""` | Ed25519 public key (`base64url:` prefixed) that verifies the license signature. Required when `enable_pro_license`. |
| `enable_bedrock_ai` | false | Grant the Lambda role `bedrock:InvokeModel`/`InvokeModelWithResponseStream` for the configured Claude model and route the AI studio (WorkflowGeneration) flows to Amazon Bedrock. |
| `bedrock_ai_model` | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | Bedrock model id for the AI studio flows (cross-region Claude Sonnet 4.5 inference profile). |
| `bedrock_ai_region` | `us-west-2` | Region the server invokes Bedrock in. |
| `enable_amazon_location_geocoding` | false | Provision an Amazon Location place index, grant the Lambda role `geo:Search*`/`DescribePlaceIndex` on it, and route `Geocoding:DefaultProvider` to `amazon-location` (Nominatim explicitly disabled). |
| `amazon_location_place_index_name` | `""` (→ `<name_prefix>-<environment>-geocode`) | Name of the Amazon Location place index. |
| `amazon_location_data_source` | `Esri` | Upstream data provider for the place index (`Esri` or `Here` — not OpenStreetMap). |
| `amazon_location_intended_use` | `SingleUse` | `SingleUse` (no result storage) or `Storage`. |
| `request_secret_reference_allowed_environment_variables` | `[]` | Exact environment variable names a request may name as `env:NAME`. Rendered as `Security__RequestSecretReferences__AllowedEnvironmentVariables__<n>`. |
| `request_secret_reference_allowed_environment_variable_prefixes` | `[]` | Environment variable name prefixes a request may name as `env:NAME` (never matches a name containing `__`). Rendered as `Security__RequestSecretReferences__AllowedEnvironmentVariablePrefixes__<n>`. |
| `request_secret_reference_allowed_secret_reference_prefixes` | `[]` | Whole-reference prefixes for the other providers, including the provider segment, e.g. `aws:secretsmanager:honua/imports/`. Rendered as `Security__RequestSecretReferences__AllowedSecretReferencePrefixes__<n>`. |
| `request_secret_reference_secret_arns` | `[]` | Secrets Manager ARNs (trailing `*` allowed) that the Lambda role and the geoprocessing Batch job role may read to resolve allowlisted `aws:secretsmanager:` references outside this module's own secrets. The allowlist alone does not authorize the read. |
| `request_secret_reference_kms_key_arns` | `[]` | Customer-managed KMS keys for those secrets, granted `kms:Decrypt` alongside them. |

See `variables.tf` for the complete list.

## Redis operation key-ring certificate

Whenever Redis is configured (`redis_enabled = true`, the default, or a
caller-owned `redis_connection_string`), the server composes the durable
operation secret channel and refuses to start without its key-ring certificate.
Every Redis-backed deployment therefore requires
`operation_key_ring_certificate_secret_arn`. Omission fails planning with an
actionable error; Redis-off neither requires nor injects a certificate. The
example stack forwards the same input and defaults to an empty ARN, so a new
Redis-on cell fails closed until protected material is supplied. The module does
not generate a private key in Terraform state or use a shared test key.

The ARN must identify an existing operator-owned Secrets Manager secret. Its
value must be standard base64 PKCS#12 with a private key, or a JSON bundle
`{"pkcs12":"<base64>","password":"<PKCS#12 password>"}`. Retain the same
certificate for the lifetime of the Redis key ring and across function versions
and alias rollbacks; a new certificate cannot decrypt the old ring. Store and
rotate it separately from Redis. Never put the bundle, its password, or a
private key into tfvars or `additional_env` (the module rejects the
`Operations__SecretChannel__KeyRingCertificate*` keys there).

```hcl
redis_enabled                             = true
operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
```

Lambda cannot resolve Secrets Manager into environment variables the way ECS
task `secrets` do, so the function (and the control-plane event functions that
share its environment) receives only a reference:
`Operations__SecretChannel__KeyRingCertificatePkcs12 = "aws:secretsmanager:<name-or-arn>"`
(the secret's name when it is in the function's account and region; see
[Lambda environment budget](#lambda-environment-budget)).
At startup the server resolves that reference with the function role, writes
the bundle to a unique private temporary file (Unix mode 0600) and loads its
certificate; the Redis data-protection ring still requires certificate
encryption. Use a server image containing that resolution boundary (honua-server
`StartupConfigurationHelpers.EnsureKeyRingCertificateMaterializedAsync`). No
secret value is read or written by this module, and the value never appears in
the Lambda configuration.

The module grants `secretsmanager:GetSecretValue` on exactly this secret to the
API function role and, when `enable_control_plane_events = true`, to the event
function role, only while Redis is configured. For a customer-managed
encryption key, supply `operation_key_ring_certificate_secret_kms_key_arn`; the
module grants `kms:Decrypt` and `kms:DescribeKey` on that exact key to the API
function role and, when `enable_gp_batch` is on, the GP Batch job role (the
event role already holds `kms:Decrypt`). The operator must
also ensure the secret resource policy and KMS key policy permit these roles,
and that any `permissions_boundary_arn` admits the secret: the release-cell
boundary from `bootstrap/aws-release-cells` admits only cell-namespaced secrets
unless its `runtime_operation_key_ring_certificate_secret_arns` (and
`..._kms_key_arns`) name this one. A
valid ARN alone does not prove the secret exists, is accessible, or contains
valid PKCS#12: Terraform checks the input contract without reading the private
key, and the server rejects missing, inaccessible or invalid content at startup
(the function never reports ready). When `enable_gp_batch` is on, the GP Batch
job definitions carry the same `ConnectionStrings__redis` and
`Operations__SecretChannel__KeyRingCertificatePkcs12` references as the Lambda:
the worker runs the same server image and reports job state through the same
durable Redis job store, so without them a submitted job never leaves
`running`. The job role is granted read on both secrets, the Batch security
group gets Redis egress, and a module-managed Redis admits the Batch security
group. The serverless root's deploy contract
lists the ARN as `secret_refs.operation_key_ring_certificate` while Redis is
configured (module output `operation_key_ring_certificate_secret_arn`).

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

Lambda cannot resolve Secrets Manager into environment variables, so the API
function, the control-plane event functions and the GP Batch job definitions
all receive the reference
`AuditLog__ChainVerification__Key = "aws:secretsmanager:<name-or-arn>"` (the
Lambdas carry the name when the secret is in their account and region, the job
definitions the ARN; see [Lambda environment budget](#lambda-environment-budget)), which the
server resolves at startup with each process's own role (honua-server
`StartupConfigurationHelpers.SecuritySecretReferenceKeys`; use an image that
includes it). The module grants `secretsmanager:GetSecretValue` on exactly
that secret to the function, event and GP job roles, and `kms:Decrypt` on a
supplied customer-managed key. The serverless root's deploy contract lists the
ARN as `secret_refs.audit_chain_key`. Under the release-cell permissions
boundary the secret must also be admitted: list it in
`bootstrap/aws-release-cells` `runtime_audit_chain_key_secret_arns`.

## Image repository policy

Lambda pulls a container image only when the image's ECR repository policy lets
the Lambda service retrieve it. ECR keeps one policy document per repository, so
whoever writes it replaces every statement in it, and whoever destroys it removes
it for every stack that shares the repository. `image_repository_policy_mode`
names the owner:

- `owned` (default): this stack owns the repository. The module installs a policy
  that grants `lambda.amazonaws.com` `ecr:BatchGetImage` and
  `ecr:GetDownloadUrlForLayer` for this account's functions in this region, and
  deletes it on destroy. A plan is refused when `image` is in another account's
  or region's registry, because that repository's policy is not this stack's to
  write.
- `reuse`: the repository is shared, for example the standing `honua-server`
  repository certification cells install from. Its owner must already authorize
  Lambda retrieval for the deploying account. The module makes no ECR
  control-plane call: it neither reads, writes nor deletes the policy, so a role
  explicitly denied `ecr:SetRepositoryPolicy` on the shared repository can still
  install from it. The digest pin on `image` and `lambda_architectures` apply
  exactly as in `owned`.

Changing an applied stack from `owned` to `reuse` plans a delete of the policy
it installed. If other stacks now depend on that policy, remove it from state
first (`terraform state rm 'module.<name>.aws_ecr_repository_policy.lambda_image_access[0]'`).
An applied `owned` stack upgrading to this version plans a move from
`aws_ecr_repository_policy.lambda_image_access` to `...lambda_image_access[0]`
and no policy change.

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
on the API Lambda, the control-plane event Lambdas and the GP Batch job definitions (the Rules count toward the [Lambda environment budget](#lambda-environment-budget)); unset fields render nothing, and the `operations_policy_environment`
output shows what was rendered. Set rules here or through `additional_env`, not
both, so one source owns the indexes.

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

Entries are rendered in list order into the Lambda environment and, when `enable_gp_batch` is on, the geoprocessing Batch job definitions. For
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

`aws-serverless` also copies to the geoprocessing Batch job exactly the `additional_env` entries the environment allowlists permit (an exact name, or a prefix match on a name without `__`), because the job does not otherwise receive `additional_env`.

Server images that predate the setting ignore these variables, so they can be
set before upgrading; deployments that already rely on request-supplied
references should set matching entries before moving to an image that includes
the setting.

## Licensing

The 2026.1 release ships with licensing **disabled** (operator ruling
2026-09-12; honua-server #4721). With no license inputs the module declares

- `Licensing__Mode = Disabled`

on the Lambda, on both control-plane event handlers, and on the geoprocessing
Batch job definition — and creates no license secret and grants the execution
role no access to one.

The mode is declared rather than inferred. honua-server's own default is
`Licensing__Mode=Enabled`, which with no license source resolves to the
**Community** edition and gates editing, sync, streaming and geocoding; a
candidate deployed with no license inputs would then look licensed-but-crippled
instead of licensing-disabled. In `Disabled` mode the server loads and validates
nothing, registers no capacity meter, activates every `FeatureCatalog`
entitlement, and its admin surface reports it:
`GET /api/v1/admin/license` answers `mode: disabled`, `edition:
Unlicensed-2026.1`, `validationState: Disabled`. The live AWS harness asserts
exactly that and treats a Community edition as a failure, not a fallback
(`validation/scripts/aws/run-aws-terraform-integration.sh`).

Set `licensing_mode = "Enabled"` (or supply an envelope, below) to opt a
deployment into licensing. Licensing hardening and metering return in 2026.2.

## Pro license (Secrets Manager delivery)

Optional, **off by default**; this is the 2026.2 path. The signed Pro license envelope (~2KB) does not fit
Lambda's 4KB total environment-variable budget, so when `enable_pro_license = true`
the module stores the envelope in a dedicated Secrets Manager secret
(`<name_prefix>-<environment>/license-pro`), grants the Lambda role
`secretsmanager:GetSecretValue` on it, and injects:

- `Licensing__LicenseContentSecretRef = aws:secretsmanager:<secret-name-or-arn>` — the server
  resolves and validates the envelope at startup (`Honua.Aws` Secrets Manager resolver).
- `Licensing__TrustedKeys__<pro_license_key_id> = <pro_license_trusted_public_key>` — the
  Ed25519 public key that verifies the signature.

The envelope's `keyId` must be **hyphen-free** (e.g. `honuademo2026q2`) because it
becomes part of the `Licensing__TrustedKeys__<keyId>` env var name; the license
signature is over the payload only, so relabeling the envelope keyId is safe as long as
the trusted key still matches. Supplying an envelope forces `Licensing__Mode=Enabled`,
and a paid deployment that cannot resolve a valid license refuses to start — so
leave the envelope off rather than relying on a fallback. Cost is effectively
`$0` (one small secret; negligible reads at cold start).

```hcl
module "honua" {
  source = "../../modules/aws-serverless"
  # ...
  enable_pro_license             = true
  pro_license_content            = file("license-pro.json") # relabeled hyphen-free keyId
  pro_license_key_id             = "honuademo2026q2"
  pro_license_trusted_public_key = "base64url:Y2XgDBncW5w6n7L3YG-T6HxX51DGybWazt0_gubk30k"
}
```

## AI studio on Amazon Bedrock

Optional, **off by default**. When `enable_bedrock_ai = true`, the module grants
the Lambda execution role a least-privilege `bedrock:InvokeModel` /
`bedrock:InvokeModelWithResponseStream` policy scoped to the single Claude model
the server's Studio AI proxy uses, and injects the `StudioAiProxy__*` env
(`Enabled`, `DefaultProvider`, the `bedrock` provider's `Kind` and `Model`, plus
`Region`/`MaxTokens`/`TimeoutSeconds` only where they differ from the server's
defaults of us-west-2/4096/120) so the AI console routes to Bedrock. The
`WorkflowGeneration__*` settings are no longer emitted: honua-server removed the
options that read them (ADR-0076, #3255). The server authenticates via the AWS credential chain
(the Lambda execution role) — without this grant the AI console gets
`AccessDenied`.

The default model is the **cross-region inference profile**
`us.anthropic.claude-sonnet-4-5-20250929-v1:0`. Invoking through an inference
profile requires both the **inference-profile ARN** (in `bedrock_ai_region`) and
the underlying **foundation-model ARNs** in every member region the `us.` profile
routes to (`us-east-1`/`us-east-2`/`us-west-2`), so the grant covers all four:

```
arn:aws:bedrock:us-west-2:<account>:inference-profile/us.anthropic.claude-sonnet-4-5-20250929-v1:0
arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0
arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0
arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0
```

## Geocoding on Amazon Location Service

Optional, **off by default**. When `enable_amazon_location_geocoding = true`, the
module provisions an Amazon Location **place index** (`aws_location_place_index`),
grants the Lambda execution role a least-privilege policy scoped to that one
index (`geo:SearchPlaceIndexForText`, `geo:SearchPlaceIndexForPosition`,
`geo:SearchPlaceIndexForSuggestions`, `geo:DescribePlaceIndex`), and injects the
`Geocoding__*` env so the server's built-in `amazon-location` provider
(`Honua.Geocoding.Features.Geocoding.Providers.AmazonLocationGeocodeProvider`)
becomes the default:

```
Geocoding__DefaultProvider                           = amazon-location
Geocoding__Providers__Nominatim__Enabled             = false
Geocoding__Providers__AmazonLocation__Enabled        = true
Geocoding__Providers__AmazonLocation__Region         = <module's region>
Geocoding__Providers__AmazonLocation__PlaceIndexName = <amazon_location_place_index_name>
Geocoding__Providers__AmazonLocation__MaxResults     = <amazon_location_max_results>  # only when not 10
```

`Geocoding__Enabled` and `AmazonLocation__UseIamRole` are server defaults
(`true`) and are not emitted.

**Why this exists (honua-server#2948):** an external Nominatim (OpenStreetMap)
provider needs general internet egress. A VPC with no NAT/internet gateway
(this module's `enable_nat_gateway = false` path) cannot reach it — every
forward/reverse geocode call fails after a consistent outbound-connect
timeout (observed ~15.8s on demo.honua.io), first call or hundredth, because
the network path simply does not exist. Amazon Location is reachable over
AWS's private network via a **VPC interface endpoint**
(`com.amazonaws.<region>.geo`), so no NAT gateway is needed — but that
endpoint is VPC-specific and is **not** created by this module; the calling
root provisions it (see `stacks/aws/vpc-endpoints.tf` in the private
honua-io/honua-demo repo — honua-iac#126 — for the pattern already used for
Secrets Manager and Bedrock).

**Why Nominatim is force-disabled, not just deprioritized:** `GeocodeCoordinatorService`
tries the default provider first, then falls back through every other
*registered* provider when `EnableFailover` is on (the default).
`NominatimProviderConfiguration` defaults `Enabled = true` in its own
constructor, so it stays registered as a failover candidate unless explicitly
turned off. In a no-NAT VPC, a failover attempt to Nominatim would still incur
its own ~15.8s connect-timeout before failing — compounding, not fixing,
latency on any Amazon Location error (e.g. a misconfigured place index). This
module sets `Geocoding__Providers__Nominatim__Enabled=false` so an
Amazon-Location-side failure fails fast instead of hanging twice.

**Data source note:** results come from **Esri** (default) or **HERE**, not
OpenStreetMap — this is a full provider swap. `amazon_location_intended_use`
defaults to `SingleUse` (real-time lookups, no result storage/caching),
matching a live GeocodeServer proxy; use `Storage` only if a workflow persists
geocode results.

**Cost** (`us-west-2`, approximate, in addition to the VPC interface endpoint
the calling root provisions): the place index itself has no idle charge — you
pay per API call (`SearchPlaceIndexForText`/`ForPosition`/`ForSuggestions`),
priced per request under the selected data source's Amazon Location pricing
tier (a few dollars per 1,000 requests; demo traffic volumes are low single
dollars/month). The `com.amazonaws.<region>.geo` interface endpoint itself
costs the same as any other single-AZ interface endpoint in this account
(~$7–8/month for the ENI + a small per-GB processed charge) — see the example
root's README for the endpoint-specific cost line.

```hcl
module "honua" {
  source = "../../modules/aws-serverless"
  # ...
  enable_amazon_location_geocoding = true
  amazon_location_place_index_name = "honua-demo-demo-geocode"
  amazon_location_data_source       = "Esri"
}
```

## Serverless observability

Three opt-in toggles add observability for the demo Lambda, all default off:

- **`enable_dashboard`** creates `aws_cloudwatch_dashboard.serverless` with Lambda
  duration (avg/p90/max), errors/throttles/invocations, concurrency, API Gateway
  request/latency, plus cold-start and Lambda Insights rows when their sources are
  wired. Outputs `dashboard_name` and `dashboard_url`.
- **`enable_xray_tracing`** turns on Lambda **Active** tracing, attaches a
  least-privilege X-Ray policy (`xray:PutTraceSegments`, `PutTelemetryRecords`,
  and the `GetSampling*` reads), and injects `Tracing__XRay__Enabled=true` so the
  Honua app emits X-Ray-compatible trace IDs. Spans still export through the
  existing OTLP path to an ADOT/X-Ray collector, producing a request → PostGIS
  query → render trace in the X-Ray service map.
- **`enable_lambda_insights`** attaches the `CloudWatchLambdaInsightsExecutionRolePolicy`
  managed policy and the Insights dashboard widgets.

The custom Honua cold-start metrics (`honua.lambda.cold_start`,
`honua.lambda.init_duration_ms`) are emitted by the app through the shared meter;
they surface on the dashboard when an ADOT/EMF collector publishes them to
`honua_metrics_namespace`.

## Alias semantics

The module publishes immutable Lambda versions and keeps API Gateway bound to a stable alias. By default the alias follows the version published by the current apply. Set `lambda_alias_version` when you need to pin or move the alias intentionally, for example when an external control plane is promoting or rolling back a published version.

The module does not invent canary or previous-version state. It exposes the stable alias revision and the current published revision so a control-plane backend can observe the current state, capture the prior stable version, and move the alias honestly.

The deployed Honua app also registers its `AwsLambda` deploy target (backend `honua-gitops-aws-lambda`) from the version-pinned settings document referenced by `HONUA_SETTINGS_DOCUMENT`, so the admin API can plan and observe Lambda rollouts without a separate sidecar config file.

### Weighted alias canaries

Both inputs are off by default; with neither set, the alias routes all traffic to its version and the settings document is unchanged.

- `lambda_alias_routing = { additional_version = "43", weight = 0.1 }` adds `routing_config.additional_version_weights` to the live alias. Terraform then sends 10% of alias traffic to version 43 and the rest to the alias version. Use it for an operator-run canary. The additional version must be a published version other than the alias version.
- `lambda_deploy_canary = { weight_percentage = 10 }` lets the control plane shift the weights itself. It adds `aws.lambda.canary_weight_percentage`, `telemetry.connection` and the gate thresholds, budgets and sample floor to the deploy target. It adds a CloudWatch entry under `ControlPlane:TelemetryConnections` to the same settings document and grants the API role `cloudwatch:GetMetricData`. The backend routes the configured share to the candidate version and promotes or rolls back only after the telemetry gate settles. The server refuses a canary weight without `telemetry.connection`.

The candidate version is only known when you plan a deploy operation, and Lambda publishes per-version metrics under the `ExecutedVersion` dimension. The target therefore carries no metric queries: an alias-wide query would let the stable version's traffic mask a failing candidate. Pass `telemetry.sample_count.query` and `telemetry.latency_p95.query` as parameter overrides when you create the operation. You can also pass `telemetry.error_rate.query` when you set `error_rate_threshold`. Copy them from the `lambda_deploy_canary.query_templates` output and replace `{version}` with the desired version. Lambda publishes `Errors` only for periods with failed invocations, and the CloudWatch reader evaluates one expression. An error-ratio expression can therefore read as no evidence on a healthy candidate (honua-io/honua-server#6474). That holds the rollout and rolls it back once the evidence grace expires, so add the error-rate signal only after you have checked it against your traffic.

Changing `lambda_deploy_canary` changes the settings document hash. Carry the current `runtime_settings_retention_entry` into `retained_runtime_settings_documents` before applying, as for any document change. Terraform owns the alias, so do not apply this module while a deploy operation holds weighted traffic on it: an apply resets `routing_config` to `lambda_alias_routing`. The output reports `configured-unverified`; mock tests prove neither the expressions nor a live weight shift.

## GP on AWS Batch (Fargate Spot)

Optional, **off by default**. When `enable_gp_batch = true`, the module provisions an AWS Batch backend so Honua's geoprocessing/import jobs run on Fargate Spot instead of inline in the Lambda. The Honua server's `ExecutionJobReconciler` submits and observes jobs through the built-in `AwsBatchComputeBackend` (no extra server config — the module surfaces everything via environment variables).

```hcl
module "honua" {
  source = "../../modules/aws-serverless"

  # ... existing serverless inputs ...

  enable_gp_batch = true
  gp_batch_image  = var.gp_image_uri   # digest-pinned GENERIC (ECS) server image; see note below

  # Substrate-level inputs only (defaults shown).
  gp_batch_cpu_architecture = "X86_64"  # or ARM64 (Graviton Spot is cheaper)
  gp_batch_max_vcpus        = 16         # caps concurrency/cost; scales to zero between jobs

  # Optional: dedicated worker-gdal ECR repository for the GP image.
  create_worker_gdal_repo = true

  # Optional: let GP jobs read/write the FileStorage data bucket. Set the
  # enabled flag (plan-time-known) alongside the ARN, which is computed at apply.
  gp_batch_data_bucket_arn     = aws_s3_bucket.data.arn
  gp_batch_data_bucket_enabled = true
}
```

> **Which image for `gp_batch_image`:** the job definitions set no `command` or
> `entryPoint`, so the Batch container runs the image's own entrypoint. Pass the
> digest-pinned generic server image (the ECS image, `dotnet Honua.Server.dll`,
> x86_64 per the 2026.1 manifest), not the Lambda AOT image: the Lambda image's
> entrypoint is built for the Lambda runtime. Leaving `gp_batch_image` empty
> falls back to `image` (the Lambda image) and is only correct for images that
> serve both roles. `gp_batch_cpu_architecture` must match the image.

### Durable substrate + a POOL of size tiers — NOT per-job terraform

Terraform provisions a **durable per-environment substrate**, not a unique
per-job config. Per-job sizing is a **runtime** `SubmitJob` override applied by
the server's `AwsBatchComputeBackend` (`ContainerOverrides` resource
requirements + `RetryStrategy` + `Timeout`) — zero infra change per job:

| Knob | Where it lives | Source |
|---|---|---|
| vCPU (`batch.vcpus`) | per-submit override | job-def default only (1 vCPU) |
| memory (`batch.memory_mib`) | per-submit override | job-def default only (2048 MiB) |
| timeout (`batch.timeout_seconds`) | per-submit override | job-def baseline only |
| retry (`batch.retry_attempts`) | per-submit override | job-def baseline only |
| share identifier (`batch.share_identifier`) | per-submit override | n/a |
| **ephemeral storage** | **job-def size tier (pool)** | tier `s`/`m`/`l`/`xl` |

The **only** knob `SubmitJob` cannot override is ephemeral (scratch) storage, so
the module mints a **fixed POOL of 4 job definitions** that differ ONLY by it —
all X86_64, all the same image:

| Tier | Job definition | Ephemeral storage |
|---|---|---|
| `gp-s`  | `<name>-gp-s`  | 20 GiB (Fargate default) |
| `gp-m`  | `<name>-gp-m`  | 50 GiB |
| `gp-l`  | `<name>-gp-l`  | 100 GiB |
| `gp-xl` | `<name>-gp-xl` | 200 GiB |

The server selects the tier per job by its disk floor and submits against that
tier's job-definition ARN (from the `gp_job_definition_arns` map output) with the
runtime overrides. No terraform re-apply per job.

> **GPU** is out of scope on the Fargate-Spot path (it needs an EC2 / managed-EC2
> compute environment with a GPU instance type). The `gp_gpu_enabled` flag is a
> placeholder that provisions nothing today; leave it `false`.

What it creates:

- A **Fargate Spot** Batch compute environment (`MANAGED`, scale-to-zero — no `min_vcpus`/`desired_vcpus`, so nothing stays warm), a **job queue**, and a **pool of 4 job definitions** (`gp-s`/`gp-m`/`gp-l`/`gp-xl`) for the GP container, differing only by ephemeral storage.
- Optionally (`create_worker_gdal_repo = true`) a dedicated **`<name>-worker-gdal` ECR repository** for the GP/GDAL worker image — scan-on-push, KMS encryption, and a lifecycle policy that retains the most recent `worker_gdal_repo_max_image_count` images. Off by default; GP otherwise reuses the Lambda image via `HONUA_JOB_KIND`. The repo name is stable regardless of the flag, so an operator can pre-create + push, then enable.
- IAM: the Lambda execution role gets scoped `batch:SubmitJob` / `batch:TerminateJob` / `batch:CancelJob` on the queue + every tier's job-definition (revision wildcard), plus account-wide `batch:DescribeJobs` / `batch:ListJobs` (these do not support resource scoping). The Batch execution role gets ECR pull + CloudWatch Logs; the job role gets the same DB, Redis and operation key-ring certificate secret access the Lambda has (and optional S3), and the job definitions carry the same Redis and key-ring certificate references.
- A `ControlPlane:ExecutionWorkloads` entry injected into the Lambda env (`Backend=honua-aws-batch`, `TargetKind=AwsBatch`, `Kind=Geoprocessing`) carrying `batch.job_queue_arn` and the per-tier `batch.job_definition_arn.{s,m,l,xl}` parameters the backend reads at submit time. To fit Lambda's 4 KB environment their values are the queue **name** and each job definition's **`name:revision`** (AWS Batch accepts both for same-account resources, and the server passes them to `SubmitJob`/`ListJobs` verbatim); `batch.region` is omitted because the backend then uses the function's own region. The `gp_job_*_arn(s)` outputs still carry full ARNs.

> **Deploy identity:** enabling `enable_gp_batch` needs `batch:*` (scoped) + `iam:PassRole` for the Batch/ECS-tasks service roles. The `bootstrap/aws-serverless` deploy identity now grants these; an older bootstrap apply must be refreshed first or the Batch create calls fail.

**Cost posture** (budget-tight demo): Fargate Spot is ~70% cheaper than on-demand Fargate; the compute environment scales to zero so you pay only for the seconds a job's container runs (no idle/warm cost). At the 1 vCPU / 2 GB default, a job costs roughly **$0.012/hour** (us-east-1 Fargate Spot ~$0.0096/vCPU-hr + ~$0.00105/GB-hr) — about **$0.012 for a one-hour job, ~$0.003 for a 15-minute job**. Spot interruptions cause Batch to retry per the job-def retry baseline (server overrides per job).

Outputs (the runtime contract; ARNs are opaque config, not variable names): `gp_job_queue_arn`, `gp_job_queue_name`, `gp_job_definition_arns` (map `{ s, m, l, xl }`), `gp_job_definition_names` (same map, names), `gp_compute_environment_arn`, `gp_compute_environment_name`, `gp_job_role_arn`, `gp_execution_role_arn`, `gp_batch_workload_id`, `gp_batch_control_plane_backend_name` (all `null` when disabled), plus `gp_worker_gdal_repository_url` / `worker_gdal_repository_arn` (`null` unless `create_worker_gdal_repo`).

### Shared file storage

honua-server dispatches a background file import (an upload above
`Import:Limits:BackgroundJobThresholdBytes`) to the durable runner, which on
this module is the GP Batch workload (honua-server#5916). The API Lambda stages
the upload through `FileStorage` and the Batch worker reads it back, so both
must use the same S3 bucket. With the server's default `Local` provider each
process only sees its own disk, and the server answers background imports with
HTTP 503 (`import.background` reasonCode `shared-file-storage-required`).

```hcl
  enable_gp_batch                 = true
  file_storage_provider           = "AwsS3"
  file_storage_aws_s3_bucket_name = "honua-prod-files" # operator-owned, existing
  file_storage_aws_s3_key_prefix  = "honua"
```

With `AwsS3` the module renders `FileStorage__Provider=AwsS3`,
`FileStorage__AwsS3__BucketName`, `FileStorage__AwsS3__Region` (the module
region unless `file_storage_aws_s3_region` is set) and, when the prefix is not
empty, `FileStorage__AwsS3__KeyPrefix` on:

- the API Lambda;
- the three control-plane event functions (they start from the API
  environment, and the scheduled tick runs the file-storage cleanup);
- every GP Batch job-definition tier (`s`, `m`, `l`, `xl`).

It attaches the same inline policy to the API Lambda role, the control-plane
event role and the GP Batch job role: `s3:GetBucketLocation`, `s3:ListBucket`
and `s3:ListBucketMultipartUploads` on `arn:aws:s3:::<bucket>`, and
`s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`
and `s3:ListMultipartUploadParts` on `arn:aws:s3:::<bucket>/<prefix>/*`. The
custom-code provisioning job (dependency restore only) and the custom-code job
definitions (empty environment by design) get neither. `gp_batch_data_bucket_*`
is a separate, generic grant to the GP job role only and renders no
`FileStorage__*` settings.

The four settings add about 214 bytes to each Lambda environment with a
39-character bucket and a 31-character prefix; see
[Lambda environment budget](#lambda-environment-budget) for the combinations
that no longer fit. Outputs `file_storage_shared`,
`file_storage_environment_rendered` and `file_storage_s3_resources` report what
was rendered and granted.

## Custom-code (UNTRUSTED user code) on AWS Batch — locked down

Optional, **off by default**. When `enable_customcode_batch = true`, the module provisions a **SEPARATE, deliberately hardened** Batch substrate for running **untrusted user code** (the custom-code **python** and **dotnet** runtimes — honua-server #2196). It parallels the GP substrate (Fargate-Spot scale-to-zero) but **this family runs untrusted code, so it is locked down**. The **runtime selector** (`customcode.runtime = python | dotnet`) the server sends picks **only the image**: each runtime gets its own size-tier job-def family (`customcode-python-{s,m,l,xl}` and `customcode-dotnet-{s,m,l,xl}`, tiers differing only by ephemeral storage) sharing the **identical** provider execution role, security group, queue, compute environment, and credential-free hardening — **the security posture is defined once and reused, not duplicated per runtime**:

- **Empty secrets/env on the job definition.** Unlike the GDAL job-def (which injects the DB connection string / admin password / master key from Secrets Manager), the custom-code job-def carries an **empty** `environment` and `secrets`. User code receives **only** the scoped runtime env the server adds at `SubmitJob` time (`HONUA_JOB_TOKEN`, `HONUA_API_ENDPOINT`, `customcode.output_prefix`, …).
- **No task role or cloud credentials.** Untrusted code runs on Fargate with no `jobRoleArn`, no injected secrets, and user `1001:1001`. Fargate has no EC2 instance-profile metadata endpoint. The execution role is provider-only (image pull/logs). Output and diagnostics use the server's job/attempt-bound artifact broker; the runtime verifies the exact definition before dispatch. The legacy artifact-bucket/prefix inputs are ignored and `customcode_task_role_arn` is always null. Apply this change together with the credential-free worker images and broker-capable server; old S3-upload workers are incompatible. No live AWS qualification is implied by Terraform validation.
- **Constrained egress allowlist.** The task security group is a CIDR **allowlist** (HTTPS 443 + DNS 53 to `customcode_egress_https_cidrs` / `customcode_egress_dns_cidrs`, each defaulting to the VPC CIDR only) — **not** an open `0.0.0.0/0`. Intended destinations: PyPI/GitHub (pip+clone), the Honua API endpoint, the artifact S3. Full **two-phase egress isolation** (deps-on then run-off) is a **Beta hardening (Phase 3)**; for MVP the **scoped token is the primary T1/T2 trust boundary** and the allowlist is defense-in-depth.
- A **single, shared** compute environment + job queue for **both** runtimes (so untrusted jobs never share a queue with trusted GP jobs), `assignPublicIp = DISABLED`, private subnets. Reuses the Batch **service** role (orchestration only, no user-code trust). The Lambda role gets `batch:SubmitJob`/`TerminateJob`/`CancelJob` scoped to the **custom-code** queue + **all** runtime job definitions only.
- Optionally a dedicated **per-runtime** ECR repository — `create_worker_customcode_repo = true` for `<name>-worker-customcode-python`, `create_worker_customcode_dotnet_repo = true` for `<name>-worker-customcode-dotnet` — each scan-on-push, KMS, image-count lifecycle cap, stable name. Override images directly with `customcode_batch_image` (python) / `customcode_dotnet_batch_image` (dotnet).

Outputs (cross-repo contract the server consumes; opaque ARNs): `customcode_job_queue_arn`, `customcode_job_definition_arns` (map keyed **`{runtime}.{tier}`** — `python.s`…`python.xl`, `dotnet.s`…`dotnet.xl`), `customcode_runtimes`, `customcode_compute_environment_arn`, `customcode_task_role_arn`, `customcode_execution_role_arn` (all `null` when disabled), plus `customcode_python_repository_url`/`_arn` (unless `create_worker_customcode_repo`) and `customcode_dotnet_repository_url`/`_arn` (unless `create_worker_customcode_dotnet_repo`). The server resolves `customcode.runtime` + the selected size tier to a single job-def ARN from the keyed map; both families share the same queue and credential-free Fargate posture, mirroring the GP `batch.job_queue_arn` / `batch.job_definition_arn` shape the `AwsBatchComputeBackend` already reads.

## Control-plane event triggers (TriggerMode=Event)

Optional, **off by default**. When `enable_control_plane_events = true`, the module wires the control plane to reconcile **event-driven** instead of on an in-process timer (which has no always-on host on Lambda). Set `ControlPlane__TriggerMode=Event` is injected automatically. Two extra Lambdas are created, both reusing the server image (`control_plane_events_image`, defaulting to `var.image`) and the API host's DI environment (same DB connection, Redis connection, admin/master-key secret refs, same VPC/subnets/security group so they reach Redis and Postgres):

- **Reconcile Lambda** (`HONUA_CONTROL_PLANE_LAMBDA_HANDLER=batch-event`) — fired by an `aws_cloudwatch_event_rule` matching `source = ["aws.batch"]` / `detail-type = ["Batch Job State Change"]`. The fast path: the moment a GP/import job transitions, the reconciler advances the control plane. EventBridge is granted `lambda:InvokeFunction` via an `aws_lambda_permission` scoped to the rule ARN.
- **Backstop Lambda** (`HONUA_CONTROL_PLANE_LAMBDA_HANDLER=backstop`) — fired every ~2 minutes by an `aws_scheduler_schedule` (`rate(2 minutes)`, `flexible_time_window { mode = "OFF" }`) through a dedicated scheduler IAM role. Catches anything the event path missed (dropped events, jobs with no terminal transition, drift).
- **Scheduled-tick Lambda** (`HONUA_CONTROL_PLANE_LAMBDA_HANDLER=scheduled-tick`) — drives the PERIODIC (bucket-b) control-plane maintenance ticks that on-prem run as in-process timers: the cron workflow scheduler, the job heartbeat/timeout reconciliation sweep, tile-cache expiry + eviction, the workspace / file-storage / temporary-file cleanups, and the alert digest flush. One `aws_scheduler_schedule` is created per tick **kind** (a `for_each` over `var.control_plane_scheduled_tick_schedules`, defaults mirroring the in-process cadences: cron/reconcile ~1 min, tile/digest a few minutes, cleanups 30 min–1 hour). Each schedule invokes this single Lambda with `input = jsonencode({ kind = "<ScheduledTickKind>" })`; the handler reads the kind and runs that one idempotent tick via the server's `IScheduledTickDispatcher`. All schedules (plus the backstop) live in one `aws_scheduler_schedule_group` (`${name}-cp`).

The backstop and per-kind tick schedules share **one** scheduler IAM role, whose invoke policy is scoped to exactly the backstop Lambda and the scheduled-tick Lambda (and their versions) — least-privilege, no wildcard function ARNs.

The reconcile/backstop/tick execution role mirrors the API Lambda role (`AWSLambdaBasicExecutionRole` + `AWSLambdaVPCAccessExecutionRole`) and adds `batch:DescribeJobs`, the same Secrets Manager reads the API host uses, and KMS `Decrypt`/`GenerateDataKey` for the AWS-managed Secrets Manager key.

Because the handlers live in the same image and are selected by `HONUA_CONTROL_PLANE_LAMBDA_HANDLER`, the image must bundle the `batch-event`, `backstop`, and `scheduled-tick` entrypoints (provided by the server build). Point `control_plane_events_image` at a tag that includes them if it differs from the API image. Tune `control_plane_events_memory_size` / `control_plane_events_timeout_seconds` (these Lambdas are invoked asynchronously, so they are not bound by the API Gateway 30s ceiling). Outputs: `control_plane_reconcile_function_name`/`_arn`, `control_plane_backstop_function_name`/`_arn`, `control_plane_tick_function_name`/`_arn`, `control_plane_batch_event_rule_arn`, `control_plane_scheduler_group_name`, and `control_plane_scheduled_tick_schedule_arns` (map of tick kind → schedule ARN).

> **FileStorageCleanup alternative.** On AWS the `FileStorageCleanup` tick can instead be served by an S3 lifecycle policy (cheaper, no compute). The schedule is kept by default for portability and non-S3 backends; drop the `FileStorageCleanup` key from `control_plane_scheduled_tick_schedules` if you prefer the lifecycle-policy route.

## Lambda environment budget

AWS Lambda refuses a function whose environment variables exceed **4 KB**
(keys plus values, measured as a JSON object). The three control-plane event
functions carry the API function's environment minus its HTTP-only settings
(below), plus their selectors, so the module keeps it compact and checks it:

- **Plan-time check.** Each function has a `precondition` that estimates the
  environment size (every key and value plus 6 bytes per entry plus 1, which
  reproduces Lambda's own measurement exactly) and fails the plan with the size
  when it exceeds 4096 bytes, instead of an `InvalidParameterValueException` at
  `CreateFunction` after everything else has been applied (honua-release
  e2e-cloud-aws run 38046060497 measured 4118 bytes).
- **Secrets by name.** `aws:secretsmanager:` references carry the secret's
  **name** rather than its ARN (59 bytes shorter each) when the secret is in
  the function's account and region. The server passes the id straight to
  `GetSecretValue` and signs for the function's `AWS_REGION`, and IAM still
  evaluates the secret's ARN, so the grants are unchanged. A name ending in `-`
  plus six characters (for example `<name>/connection-string`) is ambiguous
  with an ARN suffix and keeps the full ARN, as do cross-account or
  cross-region operator secrets. The GP Batch job definitions keep full ARNs.
- **No defaults restated.** Settings equal to the server's defaults are not
  emitted (`HONUA_SKIP_MIGRATIONS=false`, `HONUA_SERVE_ADMIN_UI`/`HONUA_ADMIN_UI`
  `=false`, `batch.region`, and the Bedrock and Amazon Location defaults above).
- **Immutable registry document.** `HONUA_SETTINGS_DOCUMENT` references a
  module-managed Secrets Manager JSON document containing the deployment target's
  full function ARN, explicit region, alias and migration requirement. Its
  canonical JSON hash selects a dedicated secret containing one version. Each
  published Lambda version pins that secret and version; later deployments
  cannot move its `AWSCURRENT` label or make it an unlabelled version subject to
  Secrets Manager cleanup. Both execution roles can read the exact current and
  retained secret ARNs. Before changing the document, copy the credential-free
  `runtime_settings_retention_entry` output's `hash` and `document` into the
  Git-owned `retained_runtime_settings_documents` map. Both secret resources
  use `prevent_destroy`, so omitting a prior entry blocks an ordinary update.
  Keep each entry while any published Lambda version refers to it. This module
  has no automatic retirement path; deletion requires a separate reviewed
  published-version inventory and retirement workflow. Exact retained-secret
  grants also consume the AWS managed-policy document limit (6,144 characters).
  A resource precondition checks the complete minified secret policy before
  IAM accepts an update, including retained documents and optional OIDC/KMS
  grants. If resource ARNs are not yet known during planning, this check is
  deferred until apply. Stop for a reviewed retirement design when the policy
  exceeds that budget; do not drop retained entries or widen permissions to
  make it fit. The module reserves `HONUA_SETTINGS_DOCUMENT`,
  `Settings__Document` and the complete `ControlPlane:DeployTargets` tree;
  `additional_env` cannot replace the document, override its registered target
  or append another target. Case and configuration-separator variants are also
  rejected. Unrelated custom environment settings remain available.
  Use a server image supporting the settings-document startup loader.
- **HTTP-only settings stay on the API function.** EventBridge invokes the
  control-plane event functions; the only HTTP request they serve is the web
  adapter's loopback POST to the event route, which the server admits without
  an `AllowedHosts` entry (`HostValidationMiddleware` exempts the adapter's
  loopback Host when `HONUA_CONTROL_PLANE_LAMBDA_HANDLER` is set) and answers
  only from loopback (`ControlPlaneLambdaEventEndpoint`). So they leave out
  `HostValidation__AllowedHosts__*`, `Cors__AllowedOrigins__*`,
  `SecurityHeaders__HstsHttpsOnly`, `HONUA_SERVE_ADMIN_UI`, `HONUA_ADMIN_UI` and
  `Import__Limits__BackgroundJobThresholdBytes` (read only by the HTTP import
  endpoints), whatever their source, `additional_env` included.

`tests/lambda_environment_budget.tftest.hcl` exercises realistic release cell
names, account identifiers, Redis, GP Batch, shared file storage, RDS Proxy,
optional AI services and Pro licensing. It checks the rendered environments
against the existing hard limit and required headroom, and verifies that an
oversized operator environment fails at plan time. The version-pinned registry
document removes repeated environment-key prefixes without shortening resource
identity or relying on an ambient deployment region.

## Database connection budget

Every process that runs the server opens its own PostgreSQL connection pools:
each warm API Lambda instance, each warm control-plane event Lambda instance
(reconcile, backstop, scheduled tick) and each running GP Batch job. With
Npgsql's and the server's defaults (`Limits:Connections:MaxConnectionPoolSize`
200, `MinConnectionPoolSize` 20) a few warm instances exhaust a small RDS:
honua-release e2e-cloud-aws run 38107383082 (`db.t3.micro`, `max_connections`
about 87) failed with `53300: remaining connection slots are reserved` and an
API Lambda init crash in the PostGIS preflight. The module caps each process:

| Input | Default | Rendered as |
|-------|---------|-------------|
| `lambda_db_max_pool_size` | `8` | `Limits__Connections__MaxConnectionPoolSize` and `MaxConcurrentQueries` on the API Lambda, and `Maximum Pool Size` on the module-built connection string |
| `control_plane_db_max_pool_size` | `2` | `Limits__Connections__MaxConnectionPoolSize` and `MaxConcurrentQueries` on each control-plane event Lambda |
| `gp_batch_db_max_pool_size` | `4` | `Limits__Connections__MaxConnectionPoolSize` and `MaxConcurrentQueries` on the GP Batch job, with `MinConnectionPoolSize` `0` |
| `db_connection_idle_lifetime_seconds` | `60` | `Connection Idle Lifetime` on the connection string and `ConnectionIdleLifetimeSeconds` on the GP Batch job |

The module-built connection string also carries `Connection Pruning Interval=10`
and `Timeout=15` (connect timeout); `db_connection_string_options` is appended
after them, so an operator keyword wins. The server's main `NpgsqlDataSource`
takes its bounds from `Limits:Connections`, not from the connection string,
which is why the caps are environment settings; the connection-string keywords
bound the pools the server opens straight from the configured string (for
example the startup PostGIS preflight). One secret serves every process, so it
carries the API's cap. With `existing_db_connection_string` the module does
not rewrite your string; the environment caps still apply.

`MaxConcurrentQueries` is set to the same value because the server refuses to
start when it exceeds `MaxConnectionPoolSize` (`LimitsOptionsValidator`; its
default is 200). The validator's adaptive-concurrency checks apply only when
`Limits__Connections__AdaptiveConcurrencyEnabled` is on (default off); if you
turn it on through `additional_env`, keep its query limits at or below the cap.

The Lambda functions carry only the cap and its query limit, within the
[4 KB budget](#lambda-environment-budget). A Lambda instance is frozen between
invocations, so idle pruning barely runs there and its connections stay open
until the instance is retired; the cap is what bounds them.

Keep the worst case under the database's `max_connections` (minus the slots
RDS reserves for superusers and `rds_reserved`). A frozen Lambda instance keeps
its connections, so count every instance that can exist, not just the busy
ones; reserved concurrency is what bounds that number:

```
API instances (lambda_reserved_concurrent_executions) x lambda_db_max_pool_size
  + control_plane_reconcile_reserved_concurrency x control_plane_db_max_pool_size
  + control_plane_backstop_reserved_concurrency  x control_plane_db_max_pool_size
  + control_plane_tick_reserved_concurrency      x control_plane_db_max_pool_size
  + concurrent GP Batch jobs x gp_batch_db_max_pool_size
  + one-off connections (migrations, PostGIS bootstrap)
```

With the defaults that is `API x 8 + 2 x 2 + 1 x 2 + 1 x 2 + jobs x 4`, so the
control plane holds at most 8 connections. On a `db.t3.micro` (about 87
connections, a few reserved) with 4 concurrent GP jobs: 7 API instances x 8 +
8 + 16 = 80. The API function has no reserved concurrency by default, so set
`lambda_reserved_concurrent_executions` to the instance count your database can
carry, or use a larger instance class.

**Control-plane concurrency.** EventBridge Scheduler fires one tick per kind
(several a minute with the default `control_plane_scheduled_tick_schedules`)
and the backstop every two minutes. Without a ceiling each overlapping
invocation started a new instance with its own pool, and the instances
accumulated until RDS was full (honua-release e2e-cloud-aws run 38125145738:
14x `53300` and 3x `PostGIS preflight check failed ... Startup aborted`, all in
the scheduled-tick function). The three event functions therefore have reserved
concurrency (`control_plane_reconcile_reserved_concurrency` 2,
`control_plane_backstop_reserved_concurrency` 1,
`control_plane_tick_reserved_concurrency` 1; the legacy
`control_plane_events_reserved_concurrent_executions`, when set, overrides all
three). Invocations above the ceiling are throttled and **queued, not
dropped**: the scheduler and the EventBridge rule invoke asynchronously, Lambda
keeps a throttled event and retries it, and the tick and backstop functions
keep an event for up to 15 and 10 minutes
(`aws_lambda_function_event_invoke_config`) before a stale periodic run is
discarded. The schedules also carry a `retry_policy` (10 attempts within the
same age) for delivery failures. Reserved concurrency comes out of the
account's Lambda concurrency, which must keep at least 100 unreserved.

### The budget without and with RDS Proxy

`db.t3.micro` (1 GiB) has `max_connections` about 87, of which about 82 are
usable after the superuser and `rds_reserved` slots. Per process, with the
defaults:

| Consumer | Connections |
|----------|-------------|
| Each API Lambda environment | 8 (`Limits:Connections` pool) + 1 (the startup PostGIS preflight opens its own pool from the connection string) = **9**, held while the environment is frozen |
| Control-plane event functions | reconcile 2 x 2 + backstop 1 x 2 + tick 1 x 2 = **8** |
| Each running GP Batch job | **4** (`gp_batch_db_max_pool_size`) |
| Migrations, PostGIS bootstrap, fixture seeding | **1-2** each, one-off |

GP Batch concurrency is bounded by `gp_batch_max_vcpus` divided by each job's
vCPUs: at the default 16 and the 1-vCPU `s` tier that is 16 concurrent jobs,
or **16 x 4 = 64** connections from Batch alone.

**Without the proxy** (honua-release e2e-cloud-aws run 38133126673): 6 API
environments x 9 + 8 + 2 jobs x 4 + 2 = **72**, and a seventh API environment
or a few more jobs reach 82 before any browser burst; at the Batch ceiling
(16 jobs) the worst case is 6 x 9 + 8 + 64 + 2 = **128**. PostgreSQL then
refuses with `53300: remaining connection slots are reserved`, which reaches
the API host as a failed cold start in the preflight. Pool caps and reserved
concurrency only move this line; they cannot close it while the API scales
out.

**With the proxy** (`enable_rds_proxy = true`): the server processes connect
to RDS Proxy and only the proxy connects to PostgreSQL, with at most
`rds_proxy_max_connections_percent` (90) of `max_connections`: about **78** on
a `db.t3.micro`, whatever the number of Lambda environments or Batch jobs. The
remaining slots stay free for the direct sessions that bypass the proxy:
migrations, the `enable_postgis` and role-defaults bootstrap, fixture seeding
and operators. The proxy logs in as the master user, which is not a
PostgreSQL superuser on RDS, so it competes for the same non-superuser slots
as those direct sessions: `max_connections` less
`superuser_reserved_connections` (3) and
`rds.rds_superuser_reserved_connections` (2), about **82** on a `db.t3.micro`
(`max_connections` about 87).

| `db.t3.micro`, about 82 usable slots | Proxy ceiling | Left for direct sessions |
|--------------------------------------|---------------|--------------------------|
| No proxy | none | every slot; each warm Lambda environment holds its own pool (worst case 128, below) |
| Proxy at 90% (default), server in connection mode (before honua-server #5874) | about 78, each pinned 1:1 to a client connection | about 4 |
| Proxy at 90% (default), role defaults | about 78, multiplexed | about 4 |
| Proxy at 70%, role defaults (certification cell) | about 60, multiplexed | about 21 |

Size the ceiling from the direct sessions, not from the server: with role
defaults the proxy multiplexes transactions, so a few dozen database
connections serve many more client connections. A release runner that
migrates and seeds through the direct `connection_string` (each pool capped at
`Maximum Pool Size=8` when it uses the module-built string), the PostGIS and
role-defaults `psql` sessions (one each) and an operator session or two need
up to about 20 slots, so a `db.t3.micro` cell should set
`rds_proxy_max_connections_percent = 70` (the example root passes it
through). At 90% a concurrent migration and seed can exhaust the remaining 4
slots with `53300` while the proxy itself is healthy (honua-release
e2e-cloud-aws run 38163689854). Demand above the ceiling waits up to
`rds_proxy_connection_borrow_timeout_seconds` (120) for a connection instead
of failing with `53300`, and a client connection idle for
`rds_proxy_idle_client_timeout_seconds` (600) is closed, which returns the
connections a frozen Lambda environment was holding.

**Pinning.** RDS Proxy multiplexes transactions over shared connections until
a session changes state: `SET` / `set_config`, `PREPARE` / `DISCARD`
(including a pooler's `DISCARD ALL` reset), session advisory locks, `LISTEN`,
temporary tables, cursors or a statement over 16 KB pin the client connection
to one database connection until the client disconnects. The proxy connection
string therefore adds `No Reset On Close=true` (no `DISCARD ALL` when Npgsql
returns a connection to its pool; honua-server's main data source already sets
this itself, so the keyword covers the pools opened straight from the string,
such as the preflight) and `Max Auto Prepare=0` (no automatic server-side
prepared statements; the Npgsql default, set explicitly).

By default honua-server's main data source runs `SET lock_timeout /
statement_timeout / idle_in_transaction_session_timeout` when it opens each
physical connection (`PostgresDataSourceFactory`), which pins every pooled
client connection for its lifetime: behind the proxy that meant about 78
pinned connections, with the direct sessions competing for the rest
(honua-release e2e-cloud-aws run 38163689854: `53300` through the proxy).
honua-server #5874 adds role defaults: with
`Database__SessionSettings__Mode=role-defaults` the data source issues no
session `SET` and PostgreSQL applies the values from the database role
instead. With the proxy on, the module:

- sets `Database__SessionSettings__Mode=role-defaults` on every server process
  that reads the proxy string: the API Lambda, the control-plane event Lambdas,
  the GP Batch job definitions and the custom-code provisioning job
  definitions. With the proxy off nothing is set and the server keeps its
  per-connection `SET` (direct connections do not pin). The variable costs 50
  bytes of the [Lambda environment budget](#lambda-environment-budget); the
  proxy secret is referenced by name, so with every optional feature on the
  scheduled-tick function still measures 4070 bytes.
- runs, as the master user on the direct endpoint during apply
  (`null_resource.db_role_session_defaults`, the `enable_postgis` `psql`
  pattern, before the proxy target is registered):

  ```sql
  ALTER ROLE "<db_username>" SET idle_in_transaction_session_timeout = '60s';
  ALTER ROLE "<db_username>" SET lock_timeout = '30s';
  ALTER ROLE "<db_username>" SET statement_timeout = '30s';
  ```

  These are the server's `Limits:Connections` defaults (`LockTimeout` 30 s,
  `StatementTimeout` 30 s, `IdleInTransactionTimeout` 60 s). The module sets
  none of those limits; a check warns when `additional_env` overrides them or
  `Database__Schema`, because the server would then report drift. It re-runs
  when the endpoint, `db_username` or the statements change, and the API and
  control-plane Lambda functions depend on it, so an upgrade starts no
  role-defaults client before the role carries the values. Destroying it
  (turning the proxy off, or before a re-run) runs `ALTER ROLE ... RESET` for
  the three settings, continuing on failure so an unreachable instance never
  blocks teardown. The defaults apply to every session of the master role,
  including direct migration, seeding and operator sessions; a long-running
  one should `SET statement_timeout = 0` for itself. It needs `psql`
  and a route to the instance like `enable_postgis`, so it follows
  `enable_postgis` unless `rds_proxy_set_role_session_defaults` says
  otherwise. When the module does not run it,
  `rds_proxy_role_session_defaults_applied` is `false` and
  `rds_proxy_role_session_defaults_sql` holds the statements to run; until
  then sessions run without these timeouts.

The server verifies the role defaults once at startup and logs event 5870 with
the exact `ALTER ROLE` statements when they are missing or differ. `ALTER ROLE
... SET` reaches only sessions that start afterwards. On a new deployment the
proxy opens no backend before the statements ran, but when you turn role
defaults on for an existing proxy (or change the values), backends the proxy
already holds keep the old settings until it retires them: idle backends above
`rds_proxy_max_idle_connections_percent` are closed, and a pinned backend
closes with its client (`rds_proxy_idle_client_timeout_seconds`). A lower idle
percentage (for example 20) recycles them sooner; rebooting the instance once
starts clean.

What can still pin a client connection with role defaults: the server's
prepared-statement cache (`Database:QueryCache:EnableAutomaticCaching`, on by
default; `PREPARE` pins), session advisory locks (migrations, background
schedulers) and the tenant `set_config` calls of some feature-store paths.
Those pins end when the client disconnects, so the ceiling, the borrow queue
and idle-client reaping still protect the database. The module leaves the
query-cache default alone; if `DatabaseConnectionsCurrentlySessionPinned`
stays high, set `Database__QueryCache__EnableAutomaticCaching=false` through
`additional_env` (55 bytes of the Lambda environment budget; the module checks
the resulting total at plan time). Watch
`DatabaseConnectionsCurrentlySessionPinned` and
`DatabaseConnectionsBorrowLatency` in CloudWatch.

**What stays on the direct endpoint.** The proxy is reachable only inside the
VPC, so the `connection_string` secret (`db_connection_secret_arn`, the
example root's `migrate_db_connection_secret_arn`, the `db_connection_string`
output) keeps the instance endpoint for migrations and seeding from a runner
admitted through `db_publicly_accessible` + `db_additional_ingress_cidrs`. The
Lambda functions and GP Batch jobs read a second secret,
`<name>/db-proxy-connection` (`runtime_db_connection_secret_arn`), whose Host
is the proxy. The `enable_postgis` local-exec (`CREATE EXTENSION` as the master
user) also stays direct: the runner's CIDR is admitted on the RDS security
group only. The direct Lambda and Batch ingress rules on the RDS security
group stay in place, so an in-VPC migration task on the Lambda security group
still works. The proxy is not available with `existing_db_endpoint`; put a
proxy in front of your own database and pass its endpoint instead.

**Cost.** RDS Proxy bills per vCPU-hour of the target instance (us-east-1
about $0.015/vCPU-hour, minimum two vCPUs): a `db.t3.micro` (2 vCPUs) costs
about $0.03/hour, roughly $22/month.

**Deploy identity.** Creating the proxy needs `rds:CreateDBProxy`,
`rds:ModifyDBProxy`, `rds:ModifyDBProxyTargetGroup`,
`rds:RegisterDBProxyTargets`, `rds:DeregisterDBProxyTargets`,
`rds:DeleteDBProxy`, and `iam:PassRole` of the proxy role to
`rds.amazonaws.com`; the `bootstrap/aws-serverless` identity grants them, and
the `bootstrap/aws-release-cells` provision lane grants them for tagged
release cells (its reaper lane deletes an owned proxy). The validation reaper
(`sweep-orphaned-validation-infra.sh`) deletes a leaked proxy by name before
the DB instance it targets.

## RDS security group rules

The module-managed RDS security group declares no inline rules. Every
PostgreSQL rule is a standalone `aws_security_group_rule`: `rds_from_lambda`,
`rds_from_cidrs` (one per `db_additional_ingress_cidrs` entry),
`rds_from_batch`, and the custom-code `rds_from_batch_provisioning` and
`rds_from_batch_execution`. Terraform does not support inline rules alongside
standalone rules on one group (the inline set is authoritative and strips the
others on every other apply).

**Upgrading a deployment created before this change.** The Lambda and CIDR
rules already exist in AWS as former inline rules, so creating them as
standalone resources fails with `InvalidPermission.Duplicate`. Import them
once, from the root that calls the module, before the upgrade apply (the rule
stays in place throughout, so the Lambda keeps database access):

```hcl
import {
  to = module.honua.aws_security_group_rule.rds_from_lambda[0]
  id = "<rds sg id>_ingress_tcp_5432_5432_<lambda sg id>"
}

# One per db_additional_ingress_cidrs entry.
import {
  to = module.honua.aws_security_group_rule.rds_from_cidrs["203.0.113.10/32"]
  id = "<rds sg id>_ingress_tcp_5432_5432_203.0.113.10/32"
}
```

New deployments need nothing.

## CORS

honua-server is the only CORS source on this module, exactly as on
`modules/aws-ecs`. `cors_allowed_origins` renders `Cors__AllowedOrigins__<n>`
and nothing else; the HTTP API has no `cors_configuration`.

An HTTP API with `cors_configuration` answers every `OPTIONS` preflight itself
and replaces the integration's CORS response headers with its own fixed
policy. That policy cannot follow the server's: honua-server also allows
`PATCH` and `HEAD`, its own allowed-header list, its exposed headers
(`ETag`, `Content-Range`, gRPC status headers and so on) and, when
`Cors__AllowCredentials` is set, credentialed requests. Without gateway CORS,
preflights match the `ANY /` and `ANY /{proxy+}` routes (`ANY` includes
`OPTIONS`; the routes have no authorizer), reach the Lambda, and the server's
CORS middleware answers them. Server CORS settings such as
`Cors__AllowCredentials` or `Cors__PreflightMaxAgeMinutes` go through
`additional_env`.

## Custom domain

Lambda deployments take the same domain inputs as the ECS module
(`modules/aws-ecs`: `domain_name`, `route53_zone_id`), so the API can be served
on any domain you own (any TLD; the Route 53 hosted zone must be in the
deploying account), and browser clients whose CSP admits only HTTPS hosts under
your own domain can reach it. With both set, the module creates and owns:

| Resource | Purpose |
|----------|---------|
| `aws_acm_certificate.api` | Certificate for `domain_name`, DNS-validated. |
| `aws_route53_record.api_cert_validation` | Validation CNAME(s) in `route53_zone_id`. |
| `aws_acm_certificate_validation.api` | Waits for issuance before the domain is created. |
| `aws_apigatewayv2_domain_name.this` | `REGIONAL` API Gateway custom domain, `TLS_1_2` policy. |
| `aws_apigatewayv2_api_mapping.this` | Maps the domain to the HTTP API's `$default` stage. |
| `aws_route53_record.api_alias` | Alias `A` record `domain_name` -> the custom domain's regional target. |

`terraform destroy` removes all of them, so a teardown that checks the cell's
own certificate and DNS records finds nothing left. The execute-api endpoint
stays enabled (`api_endpoint`); `service_url` becomes `https://<domain_name>`
(else it equals `api_endpoint`), and `custom_domain_url`,
`custom_domain_name`, `custom_domain_alias_fqdn` and
`custom_domain_certificate_arn` are set (else `null`). The Lambda function,
its alias and any Function URL are unchanged.

Server settings behind the custom domain, compared with the ECS module's
`alb_tls_environment`:

- **Host validation.** The Lambda allowlists `*.execute-api.<region>.amazonaws.com`.
  API Gateway passes the client's `Host` (the custom domain) in the event and
  Lambda Web Adapter replays it, so the module appends `domain_name` to
  `HostValidation__AllowedHosts__<n>` (after `additional_allowed_hosts`,
  without duplicating it). It counts against the
  [4 KB budget](#lambda-environment-budget).
- **Public base URL.** honua-server builds absolute links (publication URLs,
  OGC and STAC self links, admin OIDC redirect URIs) only from
  `Public:BaseUrl` / `PUBLIC_BASE_URL`, never from the request host; without it
  they fall back to a loopback origin and admin OIDC refuses to start outside
  Development. The module therefore sets `Public__BaseUrl = https://<domain_name>`
  (reported by the `public_base_url` output). `public_base_url` overrides it,
  for example when a CDN on your domain fronts the API, and works without a
  custom domain too; it must be an absolute `http`/`https` URL (optionally with
  a port or path prefix) because the server ignores a bare host name. A
  `Public__BaseUrl` or `PUBLIC_BASE_URL` already in `additional_env` is kept and
  wins; setting both fails the `public_base_url_single_source` check. The entry
  is about 30 bytes plus the host name against the 4 KB budget; the release
  Redis-on cell on a 55-character customer domain keeps its 256-byte margin
  (`tests/lambda_environment_budget.tftest.hcl`). If `public_base_url` names a
  host other than `domain_name` that reaches the Lambda with its own `Host`
  header, add it to `additional_allowed_hosts`.
- **HSTS.** `SecurityHeaders__HstsHttpsOnly = "false"` is already set on every
  Lambda (API Gateway is HTTPS-only and Lambda Web Adapter's last hop is HTTP),
  which matches what ECS sets once its ALB terminates TLS.
- **Forwarded headers.** API Gateway sets `X-Forwarded-Proto: https` and Lambda
  Web Adapter forwards it, but `ASPNETCORE_FORWARDEDHEADERS_ENABLED` is not set
  here, on the custom domain or on execute-api. honua-server builds absolute
  links from `Public:BaseUrl` (above), never from the request host or scheme,
  and HSTS does not depend on the scheme here, so the domain does not need it.
- **CORS.** The server answers CORS from `Cors__AllowedOrigins__<n>` on the
  custom domain and on execute-api alike (see [CORS](#cors)). List the browser
  origins (Console, site), not the API domain.

```hcl
module "honua" {
  source = "../../modules/aws-serverless"
  # ...
  domain_name     = "gis.example.com"
  route53_zone_id = "Z0123456789ABCDEFGHIJ"
  # Optional: a different public origin, for example a CDN on your domain.
  # public_base_url = "https://maps.example.com"
}
```

## Constraints

- **API Gateway timeout**: HTTP API has a 30-second max integration timeout. Keep `lambda_timeout_seconds` in sync.
- **Cold starts**: Use an AOT Lambda image (`vX.Y.Z-lambda-aot`) for faster cold starts. Consider provisioned concurrency for latency-sensitive workloads.
- **Concurrent migrations**: Multiple Lambda invocations may attempt migrations simultaneously. Always set `skip_migrations = true` in production.

## Outputs

See `outputs.tf` and `custom-domain.tf` for the API endpoint URL (`api_endpoint`, and `service_url`, which is the custom domain when one is configured), RDS connection string, and secret
references. `admin_password_secret_arn` is the always-present, non-sensitive
string ARN of the module-managed admin-password secret. Treat it as opaque and
pass it directly to consumers: AWS appends a random suffix to Secrets Manager
ARNs, so callers must not derive it from the configured secret name. This
output does not expose the admin-password value.

With `enable_rds_proxy`, `rds_proxy_endpoint` and `rds_proxy_arn` describe the
proxy (both `null` when it is off), and `runtime_db_connection_secret_arn` is
the connection-string secret the Lambda functions and GP Batch jobs read (the
proxy string; without the proxy it equals `db_connection_secret_arn`, which
always holds the direct instance endpoint for migrations).
`rds_proxy_connection_pool` reports the default target group's
`max_connections_percent`, `max_idle_connections_percent` and
`connection_borrow_timeout`, `rds_proxy_role_session_defaults_sql` the
`ALTER ROLE` statements the server expects, and
`rds_proxy_role_session_defaults_applied` whether the module ran them (`null`,
`null` and `false` when the proxy is off).

The module also emits Honua control-plane handoff metadata:

- `environment`
- `aws_region`
- `lambda_function_name`
- `lambda_function_arn`
- `lambda_function_version`
- `lambda_alias_name`
- `lambda_alias_arn`
- `lambda_alias_invoke_arn`
- `lambda_alias_function_version`
- `control_plane_target_kind = "AwsLambda"`
- `control_plane_backend_name = "honua-gitops-aws-lambda"`
- `control_plane_target_id`
- `control_plane_target_name` and `control_plane_target_resource_id`
- `control_plane_current_revision`
- `control_plane_desired_revision`
- `control_plane_telemetry_policy = "honua-http"`

## Certification inputs

Workload images must be digest-pinned (`registry/repository@sha256:<64 hex>`).
Bedrock uses the workload IAM role and configures `StudioAiProxy` as well as
`WorkflowGeneration`. See [AWS certification inputs](../../../../docs/devops/aws-certification-inputs.md)
for N-1/N pins, custom-code worker requirements, OIDC roles and live evidence limits.


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

The identity belongs to the API Lambda's published configuration. Keeping the live
alias on a prior published version preserves that version's prior identity while
staging the candidate. Existing 4 KB environment preconditions still apply; this
input adds no permissions and performs no alias promotion.

The operator contract is `honua.operator-contract/v2`. The deprecated
`customcode_task_role_arn` is always null; v1 consumers are incompatible with
this credential-free worker contract. Deploy the v2-aware DevOps consumer and
the server broker/scoped-authentication runtime together; do not reinterpret
an older apply receipt as v2. See [the migration policy](../../../../docs/operator-contract.md#migration-from-v1).

## Model transcript signing

`transcript_signing` defaults to `null`. To enable it, supply an approved public
key ID and existing signing-secret ARN, with optional immutable version ID and
exact KMS key ARN. No private value is read by Terraform. See the
[operator signing guide](../../../../docs/devops/aws-transcript-signing.md) for
runtime IAM, public-manifest binding, rotation and the Lambda server dependency.

### Rollback target eligibility

Image rollback never reverses migrations. Before you move the alias back to an earlier version or image, check that
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

### Retaining Batch revisions for rollback

`gp_batch_retain_prior_definitions = true` is an explicit, temporary rollback-window setting.
Set it before changing the Batch image when a retained published Lambda version still pins the
previous `name:revision`. AWS normally deregisters that revision when Terraform creates its
replacement, so moving the alias back alone would not restore job submission. The default stays
`false` for ordinary lifecycle management.

This option keeps every prior tier revision ACTIVE. Record their exact ARNs from
`gp_job_definition_arns` before the update. After every affected job has reached a terminal state
and the rollback window is closed, deregister only those recorded revisions through the normal
approved operator flow. Destroying the current Terraform resource does **not** deregister older
retained revisions. Reverting the flag later also does not discover or remove older revisions.
The release harness owns this cleanup for its ephemeral, run-bound stacks; this input does not
claim a successful update, rollback, exactly-once execution or cloud qualification.

### Agent deployment identity

The server's registered deploy target uses the full Lambda function ARN and an
explicit AWS region. This lets the agent compare its provider observations with
the server's configured account, region and function before accepting an
installation handoff. The ARN is derived from the module's provider identity and
function name; it does not require reading secrets or create a self-reference
through the function environment. Non-default aliases remain explicit.

`runtime_binding_contract` contains configured resource identities, not proof
that the installed endpoint works. The agent must still verify the actual alias,
published version, API Gateway integration/route and current server authority.
The existing 4 KB environment limit and release configuration budget checks
remain mandatory.
