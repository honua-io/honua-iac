# AWS serverless root (Lambda + optional GP on Batch)

Deployable root for the `modules/aws-serverless` module: Honua on AWS Lambda
behind API Gateway, with RDS PostgreSQL/PostGIS, optional ElastiCache Redis and,
when `enable_gp_batch = true`, geoprocessing/import jobs on a scale-to-zero AWS
Batch (Fargate Spot) queue. Lambda plus Batch is the 2026.1 Lambda+Batch cell.

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in image + secrets
terraform init
terraform plan -var-file=presets/small.tfvars.example
```

## Agent handoff

This root emits `deployment_contract`, `validation_contract`, and
`operations_contract` using [operator contract v2](../../../../docs/operator-contract.md).
Pass the release and Terraform state identity through `operator_contract_identity`;
omitting it produces an explicitly unqualified development contract. The contract
contains secret locators, never credential values. Its database reference follows
the runtime connection, including RDS Proxy; migration retains its separate
direct connection reference.

Immutable identity is refused when the configured image differs from the claim,
the serving alias still selects an older configured version, or the alias's
image/execution role differs from the claim. Complete the deployment or restore
the matching configuration before creating the handoff. Matching contract output
alone does not prove an installation: the agent must still bind the successful
apply receipt and independently verify the actual runtime, readiness, and access.

## Redis and the operation key-ring certificate

`redis_enabled` defaults to `true`, and a Redis-connected server refuses to start
without its operation key-ring certificate. Set
`operation_key_ring_certificate_secret_arn` (and
`operation_key_ring_certificate_secret_kms_key_arn` for a customer-managed key)
to an operator-owned Secrets Manager PKCS#12 bundle; planning fails with an
actionable error when Redis is on and it is missing. Only the ARN enters
Terraform: the Lambda receives an `aws:secretsmanager:` reference and the server
reads the value with the function role. See the module README, "Redis operation
key-ring certificate".

## Audit hash-chain key

Set `audit_chain_key_secret_arn` (recommended) to an operator-owned Secrets
Manager secret holding a base64 key of at least 32 bytes. Without it audit rows
are still written but chain verification never succeeds and the
`audit-chain-integrity` health check is Unhealthy; planning warns. See the
module README, "Audit hash-chain key".

## Architecture defaults

`lambda_architectures` defaults to `["x86_64"]` and `gp_batch_cpu_architecture`
to `X86_64`, matching the 2026.1 platform manifest (`awsLambdaArchitecture:
x86_64`, `awsEcsArchitecture: x86_64`). Use arm64 only with images verified for
it.

## GP on AWS Batch (the Lambda+Batch cell)

| Variable | Default | Notes |
|----------|---------|-------|
| `enable_gp_batch` | `false` | Provisions the Batch compute environment, queue and job-definition pool and wires them into the server's ControlPlane execution-workload catalog. |
| `gp_batch_image` | `""` | Digest-pinned **generic (ECS) server image**. The job definitions set no `command` or `entryPoint`, so the container runs the image's own entrypoint; the Lambda AOT image's entrypoint is built for the Lambda runtime. Empty falls back to `honua_image_uri`, and a plan check warns. |
| `gp_batch_cpu_architecture` | `X86_64` | Must match `gp_batch_image`. |
| `gp_batch_max_vcpus` | `16` | Caps concurrent jobs and cost; scales to zero between jobs. |
| `gp_batch_data_bucket_arn` / `gp_batch_data_bucket_enabled` | `""` / `false` | Optional S3 read/write grant for the job role; set both together. |
| `use_batch_service_linked_role` | `false` | Use the operator-precreated AWS Batch service-linked role (certification cells). |

Outputs (all `null` when Batch is off): `gp_batch_enabled`, `gp_batch_image`
(the effective image), `gp_batch_cpu_architecture`, `gp_job_queue_name`,
`gp_job_queue_arn`, `gp_job_definition_names` and `gp_job_definition_arns`
(maps keyed `s`, `m`, `l`, `xl`), `gp_compute_environment_name`,
`gp_compute_environment_arn`.

## Database connections (RDS Proxy)

| Variable | Default | Notes |
|----------|---------|-------|
| `enable_rds_proxy` | `false` | Puts Amazon RDS Proxy in front of the cell's PostgreSQL and routes the Lambda functions and GP Batch jobs through it, so Lambda scale-out cannot exhaust the instance's connection slots (`53300`). Migrations keep the direct endpoint: `migrate_db_connection_secret_arn` is unchanged. About $0.03/hour on a `db.t3.micro`. See the module README's [database connection budget](../../modules/aws-serverless/README.md#database-connection-budget). Behind the proxy the server runs with `Database__SessionSettings__Mode=role-defaults`, and with `enable_postgis` (default `true`) the module sets the matching `ALTER ROLE` session defaults during apply. |
| `rds_proxy_max_connections_percent` | `90` | The proxy's ceiling, as a percentage of the instance's `max_connections`. The rest stays free for direct sessions: migrations and fixture seeding from the runner, the PostGIS bootstrap, operators. A `db.t3.micro` cell whose runner migrates and seeds directly should set `70` (about 60 proxy connections, about 21 direct slots of the about 82 usable). |
| `rds_proxy_max_idle_connections_percent` | `50` | Idle connections the proxy keeps open, as a percentage of `max_connections`; at most `rds_proxy_max_connections_percent`. Lower recycles proxy backends sooner. |
| `rds_proxy_connection_borrow_timeout_seconds` | `120` | Seconds a client waits for a connection at the ceiling before the proxy returns an error (instead of PostgreSQL's `53300`). |

Outputs: `rds_proxy_endpoint`, `rds_proxy_arn` (`null` when off).

## Browser origins (CORS)

`cors_allowed_origins` (default `[]`) lists the browser origins, such as the
Honua Console or Studio, that may call the API. Each entry becomes
`Cors__AllowedOrigins__<n>` on the server, which is the only CORS source, as on
the ECS root: API Gateway has no CORS configuration, so preflights reach the
server and its full policy applies. API-only cells called by SDKs, the CLI or
server-side clients need none.

## Operation policy rules

The server runs in `Production`, where `Operations:Policy` denies every typed
operation (for example `service.publish`) until a rule allows it.
`operations_policy_rules` (default `[]`) passes ordered first-match-wins rules
to the module, which renders them on the API Lambda, the control-plane event
Lambdas and the GP Batch jobs; see the module README's
[Operation policy rules](../../modules/aws-serverless/README.md#operation-policy-rules)
for the fields. For example:

```hcl
operations_policy_rules = [
  { operation_id = "service.publish", role = "admin", decision = "Allow" },
  { role = "admin", decision = "RequireApproval", approval_lane = "control-plane" },
]
```

## Custom domain

The root takes the ECS root's custom-domain inputs under the same names and
passes them to the module (see the module's
[Custom domain](../../modules/aws-serverless/README.md#custom-domain) section):

| Variable | Default | Description |
|----------|---------|-------------|
| `domain_name` | `""` | Custom API hostname on any domain you own, for example `gis.example.com`. Set together with `route53_zone_id`; also sets `Public__BaseUrl`. |
| `public_base_url` | `""` | Optional public origin for server-built absolute links (`Public__BaseUrl`), for example `https://maps.example.com`. Empty uses `https://<domain_name>`. |
| `route53_zone_id` | `""` | Route53 hosted zone that owns `domain_name`; the module validates the ACM certificate and creates the alias record there. |

With both set, `honua_url` and the deploy contract's `endpoint` are
`https://<domain_name>`; without them they are the execute-api endpoint. The
root also outputs `api_endpoint` (always the execute-api endpoint),
`custom_domain_url`, `custom_domain_alias_fqdn` and
`custom_domain_certificate_arn` (`null` without a domain). The certificate,
validation records, API Gateway custom domain and alias record belong to this
root's state and are removed by `terraform destroy`.

## Studio end-user authorization

`studio_end_user_authorization` (default `false`) lets any authenticated
principal use the Studio authoring API, subject to the server's per-resource
Studio authorization. The module renders `Studio__EndUserAuthorization__Enabled=true`
only when it is `true`. Off keeps the server default: only admins can author
Studio content, and a non-admin gets HTTP 403 from routes such as
`GET /api/v1/studio/package-families`.

## Large imports (background-job threshold)

| Variable | Default | Notes |
|----------|---------|-------|
| `import_background_job_threshold_bytes` | `null` | Upload size in bytes above which honua-server runs an import as a background job instead of inline. Rendered as `Import__Limits__BackgroundJobThresholdBytes` on the API Lambda and the GP Batch job definitions (not on the control-plane event functions, which serve no uploads); `null` renders nothing and keeps the server default (100 MiB). Must be a whole number greater than 0. Adds about 57 bytes to each Lambda environment. The release harness sets `67108864` (64 MiB) on Redis-on cells so the S10 large-import fixture has a background window under the 100 MiB staging cap. |

## Shared file storage (background imports on GP Batch)

| Variable | Default | Notes |
|----------|---------|-------|
| `file_storage_provider` | `Local` | `AwsS3` makes the API Lambda, the control-plane event functions and the GP Batch job definitions share one S3 bucket for `FileStorage`, which a background import accepted by the Lambda needs to run on GP Batch (honua-server#5916); with `Local` the server answers background imports with 503 (`shared-file-storage-required`). `Local` renders nothing. |
| `file_storage_aws_s3_bucket_name` | `""` | Existing, operator-owned bucket. Required with `AwsS3`; the module grants the API Lambda, control-plane event and GP Batch job roles access but does not create it. |
| `file_storage_aws_s3_region` | `""` (→ `region`) | Region of the bucket, rendered as `FileStorage__AwsS3__Region`. |
| `file_storage_aws_s3_key_prefix` | `honua` | Object-key prefix; the object grants are scoped to `<bucket>/<prefix>/*`. |

The settings add about 214 bytes to each Lambda environment. On the full release
Redis-on cell (custom domain, operation policy rules, control-plane events) the
API function measures 4077 bytes, under Lambda's 4 KB cap with 19 bytes to
spare, and the control-plane event functions (which carry no HTTP-only
settings) 3787-3793; see the module README, "Lambda environment budget". Outputs
`file_storage_shared` and `file_storage_environment_rendered` report what each
process carries. The release harness passes `file_storage_provider`,
`file_storage_aws_s3_bucket_name` and `file_storage_aws_s3_key_prefix` on
Redis-on cells (`REDIS_ON_SCALE_INPUTS`) only when the root declares every
input in that set.

## Migrations on the serverless root

`skip_migrations` defaults to `true`: concurrent Lambda cold starts must not race
to migrate the schema, so the Lambda never migrates the database. **Until
honua-server ships a `HONUA_MIGRATE_ONLY` exit mode (planned for 2026.1.x), the
release harness (or the operator) runs migrations out-of-band after `apply` and
before the cell serves traffic**:

1. Start the digest-pinned generic (ECS) honua-server image once, with
   `ConnectionStrings__DefaultConnection`, `HONUA_ADMIN_PASSWORD` and
   `Security__ConnectionEncryption__MasterKey` set from the secrets named by
   `migrate_db_connection_secret_arn`, `migrate_admin_password_secret_arn` and
   `migrate_master_key_secret_arn` (as `aws:secretsmanager:<arn>` references or
   resolved values).
2. Run it where the database is reachable: as an in-VPC task in
   `migrate_private_subnet_ids` with `migrate_security_group_id`, or from a
   runner admitted with `db_publicly_accessible = true` and
   `db_additional_ingress_cidrs`.
3. Wait for `GET /healthz/ready` to return 200 (the server migrates on startup),
   then stop it. The Lambda can now serve.

`migrate_required` is `true` while `skip_migrations` is on, and
`migrate_guidance` repeats these steps. When `HONUA_MIGRATE_ONLY` exists, step 3
becomes a run-to-completion exit and this section will be updated. Outputs carry
ARNs and IDs only, never secret values.


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

## Model transcript signing

The optional `transcript_signing` input passes the approved signer identity and
existing secret reference to the runtime module. It is disabled by default. See
[the signing guide](../../../../docs/devops/aws-transcript-signing.md) before
configuring protected inputs or approving a deployment.

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
