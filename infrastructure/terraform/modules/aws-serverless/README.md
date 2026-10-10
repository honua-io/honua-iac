# AWS Lambda (Serverless) Module

Deploys Honua Server to AWS Lambda (container image) behind an API Gateway HTTP API, with RDS PostgreSQL and optional ElastiCache Redis.

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
- **Migrations**: `skip_migrations` defaults to `true` for serverless, so the Lambda never migrates the database. Run migrations out-of-band before first use: run the generic (ECS) server image once against the `db_connection_secret_arn` connection string until `/healthz/ready` answers, then stop it. The deployable root `examples/aws-serverless` publishes the inputs for that step as `migrate_*` outputs; see its README, "Migrations on the serverless root". A server `HONUA_MIGRATE_ONLY` exit mode that makes this a single run-to-completion command is planned for 2026.1.x.

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

  additional_env = {
    HONUA_OBSERVABILITY = "true"
    Public__BaseUrl     = "https://gis.example.com"
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
| `cors_allowed_origins` | `[]` | Browser origins (Console/Studio) rendered as `Cors__AllowedOrigins__<n>` and as API Gateway CORS. Empty or `null` configures no CORS; API-only cells need none. |
| `lambda_alias_name` | `live` | Stable alias used for API Gateway traffic and control-plane rollback. |
| `lambda_alias_version` | `null` | Optional published version to pin the stable alias to; defaults to the version published by the current apply. |
| `enable_postgis` | **false** | Enable PostGIS + PostGIS Raster on RDS. **Set to true.** |
| `existing_db_endpoint` | `""` | Reuse an existing PostgreSQL endpoint (must be paired with `existing_db_connection_string`). |
| `existing_db_connection_string` | `""` | Reuse an existing PostgreSQL connection string (skips RDS provisioning and PostGIS local-exec). |
| `skip_migrations` | true | Skip auto-migrations. Run them out-of-band for serverless. |
| `db_instance_class` | `db.t3.micro` | RDS instance class. |
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

The deployed Honua app also self-registers its `AwsLambda` deploy target through environment-based `ControlPlane__...` settings, so the admin API can plan and observe Lambda rollouts without a separate sidecar config file.

If you want staged Lambda rollout instead of direct alias cutover, add a deploy-target parameter such as `lambda.canary_weight_percentage=10` and a valid `telemetry.connection` in the Honua control-plane configuration. The Lambda backend only promotes or rolls back the alias after telemetry settles.

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

## Custom-code (UNTRUSTED user code) on AWS Batch — locked down

Optional, **off by default**. When `enable_customcode_batch = true`, the module provisions a **SEPARATE, deliberately hardened** Batch substrate for running **untrusted user code** (the custom-code **python** and **dotnet** runtimes — honua-server #2196). It parallels the GP substrate (Fargate-Spot scale-to-zero) but **this family runs untrusted code, so it is locked down**. The **runtime selector** (`customcode.runtime = python | dotnet`) the server sends picks **only the image**: each runtime gets its own size-tier job-def family (`customcode-python-{s,m,l,xl}` and `customcode-dotnet-{s,m,l,xl}`, tiers differing only by ephemeral storage) sharing the **identical** task role, execution role, security group, queue, compute environment, and empty-secrets hardening — **the security posture is defined once and reused, not duplicated per runtime**:

- **Empty secrets/env on the job definition.** Unlike the GDAL job-def (which injects the DB connection string / admin password / master key from Secrets Manager), the custom-code job-def carries an **empty** `environment` and `secrets`. User code receives **only** the scoped runtime env the server adds at `SubmitJob` time (`HONUA_JOB_TOKEN`, `HONUA_API_ENDPOINT`, `customcode.output_prefix`, …).
- **A minimal, separate task role.** Distinct from the GP job role: **no** Secrets Manager, **no** RDS reach (no SG ingress to RDS, no 5432 egress), **no** broad S3 — **only** `s3:GetObject`/`PutObject` scoped to the per-job artifact prefix (`<customcode_artifact_prefix>/*` under `customcode_artifact_bucket_arn`). Without an artifact bucket the task role has **zero** inline permissions (image pull is on the execution role). The job's Honua callback uses the **scoped `HONUA_JOB_TOKEN`** (server-injected env), **not** AWS IAM.
- **Constrained egress allowlist.** The task security group is a CIDR **allowlist** (HTTPS 443 + DNS 53 to `customcode_egress_https_cidrs` / `customcode_egress_dns_cidrs`, each defaulting to the VPC CIDR only) — **not** an open `0.0.0.0/0`. Intended destinations: PyPI/GitHub (pip+clone), the Honua API endpoint, the artifact S3. Full **two-phase egress isolation** (deps-on then run-off) is a **Beta hardening (Phase 3)**; for MVP the **scoped token is the primary T1/T2 trust boundary** and the allowlist is defense-in-depth.
- A **single, shared** compute environment + job queue for **both** runtimes (so untrusted jobs never share a queue with trusted GP jobs), `assignPublicIp = DISABLED`, private subnets. Reuses the Batch **service** role (orchestration only, no user-code trust). The Lambda role gets `batch:SubmitJob`/`TerminateJob`/`CancelJob` scoped to the **custom-code** queue + **all** runtime job definitions only.
- Optionally a dedicated **per-runtime** ECR repository — `create_worker_customcode_repo = true` for `<name>-worker-customcode-python`, `create_worker_customcode_dotnet_repo = true` for `<name>-worker-customcode-dotnet` — each scan-on-push, KMS, image-count lifecycle cap, stable name. Override images directly with `customcode_batch_image` (python) / `customcode_dotnet_batch_image` (dotnet).

Outputs (cross-repo contract the server consumes; opaque ARNs): `customcode_job_queue_arn`, `customcode_job_definition_arns` (map keyed **`{runtime}.{tier}`** — `python.s`…`python.xl`, `dotnet.s`…`dotnet.xl`), `customcode_runtimes`, `customcode_compute_environment_arn`, `customcode_task_role_arn`, `customcode_execution_role_arn` (all `null` when disabled), plus `customcode_python_repository_url`/`_arn` (unless `create_worker_customcode_repo`) and `customcode_dotnet_repository_url`/`_arn` (unless `create_worker_customcode_dotnet_repo`). The server resolves `customcode.runtime` + the selected size tier to a single job-def ARN from the keyed map; both families share the same queue/role, mirroring the GP `batch.job_queue_arn` / `batch.job_definition_arn` shape the `AwsBatchComputeBackend` already reads.

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
(keys plus values, measured as a JSON object). The API function and the three
control-plane event functions carry the same environment, so the module keeps
it compact and checks it:

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
  `=false`, the deploy target's `aws.lambda.function_name`/`aws.region`/
  `aws.lambda.alias_name=live` parameters, `batch.region`, and the Bedrock and
  Amazon Location defaults above).

Measured with `tests/lambda_environment_budget.tftest.hcl` (cell name
`honuarawsse380460-it`, 12-digit account, release secret names): the release
Redis-on cell with the key ring, audit key and GP Batch is **2934** bytes (was
4118). Every optional 2026.1 feature at once (also Bedrock, Amazon Location,
X-Ray, two CORS origins, request-secret allowlists and the control-plane event
functions) is **3981** bytes on the scheduled-tick function, under the cap but
with only 115 bytes to spare. Adding the 2026.2 Pro license on top no longer
fits the event functions, and the plan fails with the size. More headroom needs
a server-side change, for example a single `aws:secretsmanager:` reference to a
JSON settings bundle that the server expands into configuration at startup; the
server has no such source today.

## Constraints

- **API Gateway timeout**: HTTP API has a 30-second max integration timeout. Keep `lambda_timeout_seconds` in sync.
- **Cold starts**: Use an AOT Lambda image (`vX.Y.Z-lambda-aot`) for faster cold starts. Consider provisioned concurrency for latency-sensitive workloads.
- **Concurrent migrations**: Multiple Lambda invocations may attempt migrations simultaneously. Always set `skip_migrations = true` in production.

## Outputs

See `outputs.tf` for the API endpoint URL, RDS connection string, and secret
references. `admin_password_secret_arn` is the always-present, non-sensitive
string ARN of the module-managed admin-password secret. Treat it as opaque and
pass it directly to consumers: AWS appends a random suffix to Secrets Manager
ARNs, so callers must not derive it from the configured secret name. This
output does not expose the admin-password value.

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
