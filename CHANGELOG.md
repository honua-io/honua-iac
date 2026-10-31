# Changelog

Release history for the publishable Honua Terraform modules under
`infrastructure/terraform/modules/`.

Modules are distributed via **Git source at a SemVer tag**, not via the public
Terraform Registry. See [`docs/module-publishing-decision.md`](docs/module-publishing-decision.md)
for the distribution decision and [`docs/module-versioning.md`](docs/module-versioning.md)
for the versioning policy.

Tags are repo-wide `vMAJOR.MINOR.PATCH`. All Tier 1 and Tier 2 modules ship
together under a single tag. The repository starts pre-1.0 to signal that the
module input/output contracts may still change.

## Unreleased

## v0.5.0

Release for the 2026.1-rc.2 cut, containing #336, #339 and #340–#347. This is a pre-1.0 minor release
because it adds optional module inputs. Review the GP role upgrade note below before applying.

### Changed

- `aws-eks`: the `<name>-gp-job` workload role again reads only the database, master key, optional Redis
  and key-ring secrets (and their CMKs). It no longer reads the admin password or the audit-chain key and
  its CMK. honua-helm#110 scopes the GP worker environment
  (`geoprocessing.kubernetesJobs.environmentScope=worker`, the chart default), so a worker no longer
  imports or resolves those references. The new `gp_job_reads_server_secrets` input on the module and on
  `examples/aws-eks` (default `false`) restores the server's secret set from #334. Set it to `true` while
  you deploy a honua-helm chart that predates #110, or with `environmentScope=server`. Otherwise every GP
  worker fails at startup on the audit-chain reference (honua-release#1059).

### Fixed

- `aws-serverless`: `rds.force_ssl=1` now uses `apply_method` `pending-reboot`. PostgreSQL 15 already defaults that parameter to 1 and AWS refreshes the default as `pending-reboot`, so `immediate` showed the same in-place update on every plan (honua-iac#321, demo.honua.io drift). The value is unchanged, so no reboot follows.

### Added

- `aws-eks` and `examples/aws-eks`: optional Bedrock invoke on the server workload role (`enable_bedrock_ai`, default false). The grant is the configured model's inference-profile ARN plus its foundation-model ARNs in us-east-1, us-east-2 and us-west-2. The default model stays `us.anthropic.claude-sonnet-4-6`. The GP job role is not granted invoke. Quota requests for Opus 5.5 and Sonnet 5.5 TPM stay in the separate bootstrap quota root.

- `aws-serverless`, `examples/aws-serverless`: optional `studio_ai_proxy_limits` (`max_prompt_characters`,
  `max_request_bytes`, `max_event_bytes`, `max_response_bytes`), the same object `aws-ecs` already takes.
  With Bedrock enabled, set fields are published as `StudioAiProxy` in the runtime settings document.
  The server loads that document as configuration underneath environment variables. The same four
  values as Lambda environment variables measured 4155 bytes on the Redis-on cell, past the 4096 cap
  (honua-iac#282). Null adds nothing. honua-release already passes this object when the pinned root
  declares it (honua-release#1061); ECS emits the same object as environment variables and shipped in
  v0.4.4 (honua-iac#333).

### Fixed

- `aws-eks`: emit HSTS when the Service load balancer terminates TLS (#339).

### Release-cell bootstrap

- Grant `cert.demo.honua.io` record changes to the release cells, attach the grants as managed policies,
  and record the applied zone in the drift plan (#342, #345, #346).
- Grant the configured latest Bedrock models from the cell invoke policies (#344).
- Request Bedrock Opus 5.5 and Sonnet 5.5 TPM quotas; document that this account requires AWS Support
  for those quota increases (#343, #347). This release does not imply those increases were granted.

## Earlier changes since v0.3.0

### Added

- `examples/aws-serverless`: `rds_proxy_idle_client_timeout_seconds` (default 600, unchanged), passed to
  the proxy. Frozen Lambda environments keep their client connections, and a pinned connection is
  released only when the proxy closes that idle client. On a small cell a burst of new environments
  pinned every proxy connection for minutes and the next request timed out (honua-release
  e2e-cloud-aws run 40961202761; pinning at host start is honua-server#6760). The module's
  `rds_proxy_connection_pool` output now includes `idle_client_timeout`.

### Added

- `aws-ecs`, `examples/aws`: optional `studio_ai_proxy_limits` (`max_prompt_characters`,
  `max_request_bytes`, `max_event_bytes`, `max_response_bytes`), emitted as `StudioAiProxy__Max*` only
  when Bedrock is enabled. Null fields keep the server defaults. A genuine-model agent turn carries the
  whole bounded tool view plus signed provenance, which exceeds the 128,000-character default prompt limit
  (honua-release e2e-cloud-aws run 40947050732).

### Added

- `aws-serverless`, `examples/aws-serverless`: `serving_closed` (default `false`) holds a deployment closed
  until its database is migrated: reserved concurrency 0 on the API function and the control-plane event
  functions (reconcile, backstop, tick), so an early request (an internet scanner on the API Gateway URL)
  or event cannot cold-start an instance into the unrecoverable schema-floor state (honua-server#6750).
  Apply with `true`, run the out-of-band migration, apply again with `false`; pool sizing and function
  environments use the open values, so only reserved concurrency changes. New output
  `serving_reserved_concurrency`. A `lambda_reserved_concurrent_executions` of 0 no longer feeds the
  database pool sizing (it would divide by zero); the API pool falls back as if it were unset.
- `aws-serverless`: the HTTP API access log also records `requestTimeEpoch`, `responseLatency`,
  `integrationLatency`, `integrationRequestId` (the Lambda RequestId) and `integrationError`. Three 30 s
  stalls that ended in the gateway's own 503 (honua-release e2e-cloud-aws run 40832719280) logged only
  status 503 and integrationStatus 200, which cannot tell a cold start, a queued invocation and a slow
  handler apart; the RequestId joins a request to its function `REPORT` line (Duration, Init Duration).

### Changed

- `aws-ecs`, `aws-serverless`, `examples/aws`: `bedrock_ai_model` now accepts current Claude ids without
  a version suffix (for example `us.anthropic.claude-sonnet-4-6`) and OpenAI GPT models on Bedrock (for
  example `us.openai.gpt-6.1-terra`), still exact ids or `us.` profiles only. The default moves from
  Claude Sonnet 4.5 to `us.anthropic.claude-sonnet-4-6`; deployments that relied on the old default and
  an IAM boundary admitting only Sonnet 4.5 must widen that boundary or pin the old id.
- `bootstrap/aws-release-cells`: the release-cell Bedrock boundary is Claude Sonnet 4.6 and OpenAI
  GPT-6.1 Terra (each US profile plus member regions), applied 2026-10-28; Sonnet 4.5 is retired. Sonnet
  5.5 is not added yet: the account is not granted it, and its four ARNs would push the managed
  workload-boundary policy past IAM's 6,144-character limit (it is at about 6,000). Adding it means
  replacing another model's ARNs.

### Fixed

- `aws-eks`: the `<name>-gp-job` workload role now reads the same Secrets Manager references as the
  server role, adding the admin password and the audit-chain key (and its customer-managed KMS key). The
  honua-helm chart's `geoprocessing.kubernetesJobs.envFromServer` mode (default on) imports the server's
  runtime Secret and config ConfigMap into each GP Job worker, and honua-server resolves every
  `aws:secretsmanager:` security reference at startup. On honua-release e2e-cloud-aws run 40947860102
  (aws-eks/redis-on) all three S10 large-import worker Jobs exited 139 before running with `Failed to
  resolve the security setting 'AuditLog:ChainVerification:Key' from AWS Secrets Manager` /
  `AccessDeniedException`, so the import ended `Import failed.` with 0 features (honua-release#1059).
  The aws-serverless Batch job role already had this grant.
- `aws-serverless`: with `enable_rds_proxy`, every server process now runs with
  `Database:QueryCache:EnableAutomaticCaching=false`, so honua-server no longer `PREPARE`s statements
  through the proxy. `PREPARE` pins the client connection, and a frozen API Lambda environment keeps
  its pinned connection until the proxy reaps it, so the proxy could serve no more API environments
  than it had database connections. On honua-release e2e-cloud-aws run 40865466550
  (aws-serverless/redis-on, db.t3.micro) a demo burst took the API to 39 concurrent environments,
  all 25 of the proxy's allowed database connections were pinned, borrow latency reached 29 s, and
  API invocations and inits hit the 30 s Lambda timeout, which API Gateway answered with its own
  503 (integrationStatus 200); the pins held for seven minutes and also failed `/healthz/ready`, an
  API-key revoke and a datasource connection test. The Lambda functions get the setting through the
  settings document (no change to the 4 KB environment); the GP Batch and custom-code provisioning job
  definitions through `Database__QueryCache__EnableAutomaticCaching`. Upgrade note: for a deployment with the proxy on,
  this changes the settings document, so carry the current `runtime_settings_retention_entry` into
  `retained_runtime_settings_documents` before applying. Deployments without the proxy are unchanged.

- `aws-ecs`: enabling Bedrock (`enable_bedrock_ai`) now also emits the
  `StudioAiProxy__Disclosure__*` approval that honua-server's fail-closed AI disclosure policy
  requires. It approves exactly the configured `bedrock_ai_model` and `bedrock_ai_region` for the
  `studio-chat` use case. Without it every Studio model call was refused with
  "AI disclosure is not approved ...". `aws-serverless` is unchanged: the approval's seven variables
  do not fit Lambda's 4 KB environment budget alongside the release cell's other settings.

- `aws-ecs`: enabling Bedrock also sets `AiExecutionAdmission__DeploymentId` to the deployment name.
  honua-server #6597 refuses every model invocation without a named deployment whose admission
  ledger an administrator has initialized and resumed (`admin.ai.admission.initialize` / `resume`).

### Added

- `aws-ecs`: optional `bedrock_ai_data_classification` (default `unclassified`), the
  workload classification the Bedrock approval is granted at.

## v0.3.0

Third pinnable release, cut from trunk `d5b7bec` (the #312 merge commit, which
also carries #310). It is a `0.x` **minor** bump, not a patch: per
[`docs/module-versioning.md`](docs/module-versioning.md) it adds optional inputs
and changes defaults that alter apply behaviour. Upgrading changes the `aws-ecs`
RDS and ElastiCache security groups in place (their egress rules are removed);
review the plan before applying. These notes moved here from `Unreleased` after
the tag; the tagged tree still lists them under `Unreleased`.

### Changed

- `aws-ecs`: the RDS and ElastiCache security groups carry no egress rule
  (`egress = []`). RDS lost `TCP 443 to 0.0.0.0/0` (Trivy `AWS-0104`, CRITICAL)
  and Redis lost all-protocol egress to the VPC CIDR. Both only answer
  connections, and security groups are stateful, so replies are unaffected. On
  the next apply Terraform removes the old rules from existing groups in place;
  nothing is replaced. The ECS task group keeps outbound HTTPS to `0.0.0.0/0` as
  a documented exception in `.trivyignore.yaml`, to be replaced by VPC endpoints
  and an egress allow-list (#311). Founder decision D1, 2026-10-26.
- `aws-serverless`: the control-plane event functions (reconcile, backstop,
  scheduled tick) no longer carry the HTTP-only settings
  `HostValidation__AllowedHosts__*`, `Cors__AllowedOrigins__*`,
  `SecurityHeaders__HstsHttpsOnly`, `HONUA_SERVE_ADMIN_UI`, `HONUA_ADMIN_UI` or
  `Import__Limits__BackgroundJobThresholdBytes`, whatever their source
  (`additional_env` included); the API function keeps them. EventBridge invokes
  those functions and their only HTTP request is the web adapter's loopback
  POST, which honua-server admits without an AllowedHosts entry and which
  serves no CORS, HSTS, admin UI or upload. This frees 374 bytes per event
  function on the release cell (Lambda 4 KB environment budget), so the release
  Redis-on cell with shared file storage fits: reconcile 3790, backstop 3787,
  scheduled tick 3793 bytes (4164, 4161 and 4167 before).
  `import_background_job_threshold_bytes_rendered.control_plane` is now always
  `null`. The 2026.2 Pro license on top of every feature now fails the plan on
  the API function only.

### Added

- `aws-ecs`: opt-in `migration_task` (default `false`) runs migrations out of
  band with honua-server migrate-only mode (honua-server#6479). It registers a
  one-shot `<name>-migrate-task` definition with the serving image (or
  `migration_task_image`), secrets, roles, network and environment plus
  `HONUA_MIGRATE_ONLY=true`, sets `HONUA_SKIP_MIGRATIONS=true` on the stable and
  canary task definitions, and exports `migration_task` with the exact
  `aws ecs run-task`, `aws ecs wait tasks-stopped`, `describe-tasks` exit-code
  and CloudWatch summary commands. `migration_task_additional_env` carries a
  one-shot `HONUA_APPROVE_CONTRACT_MIGRATIONS` nonce to the migrator only. The
  plan refuses `HONUA_MIGRATE_ONLY` in any additional env and a manual
  `HONUA_SKIP_MIGRATIONS` while the task is on. The `aws` example passes all
  three inputs and the output through. Disabled, nothing changes.

- `aws-serverless` and the `examples/aws-serverless` root: shared S3 file
  storage, with the same inputs as `aws-ecs` (`file_storage_provider`, default
  `Local`; `file_storage_aws_s3_bucket_name`; `file_storage_aws_s3_region`,
  default the module region; `file_storage_aws_s3_key_prefix`, default
  `honua`). `AwsS3` renders `FileStorage__Provider`,
  `FileStorage__AwsS3__BucketName`, `FileStorage__AwsS3__Region` and (when the
  prefix is not empty) `FileStorage__AwsS3__KeyPrefix` on the API Lambda, the
  control-plane event functions and every GP Batch job-definition tier, and
  grants the API Lambda, control-plane event and GP Batch job roles bucket-level
  access plus object access under the prefix, so a background import accepted by
  the Lambda can run on GP Batch (honua-server#5916; without it the server
  answers 503 `shared-file-storage-required`). `Local` renders and grants
  nothing. A plan with `AwsS3` and no bucket fails. New outputs
  `file_storage_shared`, `file_storage_environment_rendered` and (module)
  `file_storage_s3_resources`. The settings add about 214 bytes per Lambda
  environment: on the full release Redis-on cell the API function measures 4077
  bytes and the control-plane event functions 3787-3793 (see Changed).
- `aws-ecs`, `aws-serverless` and the `examples/aws` / `examples/aws-serverless`
  roots: new input `import_background_job_threshold_bytes` (number, default
  `null`; must be a whole number greater than 0). When set it is rendered as
  `Import__Limits__BackgroundJobThresholdBytes` on every server process: the
  ECS primary and canary task definitions, and the serverless API Lambda,
  control-plane event functions and GP Batch job definitions. `null` renders
  nothing and keeps the server default (100 MiB). The release harness passes
  `67108864` on Redis-on cells so the S10 large-import fixture has a background
  window under the 100 MiB staging cap (honua-release#548). New module output
  `import_background_job_threshold_bytes_rendered` reports what each process
  carries.
- `aws-serverless` with `enable_rds_proxy`: every server process that reads the
  proxy connection string (API Lambda, control-plane event Lambdas, GP Batch
  and custom-code provisioning job definitions) gets
  `Database__SessionSettings__Mode=role-defaults` (honua-server #5874), so the
  server issues no per-connection `SET` and RDS Proxy can multiplex instead of
  pinning each client connection (honua-release e2e-cloud-aws run 38163689854:
  `53300` through the proxy). `null_resource.db_role_session_defaults` runs
  `ALTER ROLE "<db_username>" SET lock_timeout = '30s'`, `statement_timeout =
  '30s'` and `idle_in_transaction_session_timeout = '60s'` (the server's
  `Limits:Connections` defaults) on the direct endpoint before the proxy target
  registers; it follows `enable_postgis` unless the new
  `rds_proxy_set_role_session_defaults` input overrides it. New outputs
  `rds_proxy_role_session_defaults_sql`, `rds_proxy_role_session_defaults_applied`
  and `rds_proxy_connection_pool`. The `aws-serverless` example root passes
  through `rds_proxy_max_connections_percent`,
  `rds_proxy_max_idle_connections_percent` and
  `rds_proxy_connection_borrow_timeout_seconds` (module defaults 90 / 50 /
  120); a `db.t3.micro` cell that migrates and seeds directly should set the
  ceiling to `70`. Requires a honua-server image with #5874; an older image
  ignores the setting and keeps pinning.

- `aws-serverless` and the `aws-serverless` example root add `enable_rds_proxy`
  (default `false`). When `true`, Amazon RDS Proxy fronts the module-managed
  PostgreSQL (TLS required, Secrets Manager auth, default target group at 90%
  of `max_connections`) and the API Lambda, the control-plane event Lambdas and
  the GP Batch job definitions read a new proxy connection-string secret, so
  Lambda scale-out can no longer exhaust the instance (`53300`). The existing
  connection-string secret, `db_connection_secret_arn` and the migration
  outputs keep the direct endpoint. New outputs `rds_proxy_endpoint`,
  `rds_proxy_arn` and `runtime_db_connection_secret_arn`; tuning inputs
  `rds_proxy_max_connections_percent`, `rds_proxy_max_idle_connections_percent`,
  `rds_proxy_connection_borrow_timeout_seconds` and
  `rds_proxy_idle_client_timeout_seconds`. `bootstrap/aws-serverless` grants
  `rds:RegisterDBProxyTargets` / `rds:DeregisterDBProxyTargets`.

- `aws-serverless`, `aws-ecs` and the `aws-serverless` and `aws` example roots
  add `studio_end_user_authorization` (default `false`). When `true`, it renders
  `Studio__EndUserAuthorization__Enabled=true`, so authenticated non-admins can
  use the Studio authoring API subject to the server's per-resource Studio
  authorization. Off keeps the server default (admins only). Both modules
  output `studio_end_user_authorization_enabled`.

- `aws-serverless`, `aws-ecs` and the `aws-serverless` and `aws` example roots
  add `operations_policy_rules` (default `[]`), rendered as
  `Operations__Policy__Rules__<n>__{OperationId,Role,Tier,Decision,Reason,ApprovalLane}`
  on every server process, and an `operations_policy_environment` output. The
  server image runs in Production, where `Operations:Policy` denies every typed
  operation (for example `service.publish`) until a rule allows it, so an
  install needs rules before operations can run. `decision` is validated
  against `Allow`, `RequireApproval`, `DryRunFirst` and `Deny`.
- `examples/aws` exposes the module's `alb_enable_http_redirect` (default
  `true`, as in the module), and `aws-ecs` outputs
  `alb_http_redirect_enabled`.

### Fixed

- `aws-serverless`: the control-plane event Lambdas get reserved concurrency
  (`control_plane_reconcile_reserved_concurrency` 2,
  `control_plane_backstop_reserved_concurrency` 1,
  `control_plane_tick_reserved_concurrency` 1) so overlapping scheduled ticks
  queue on one instance instead of starting new instances that each hold a
  database pool (e2e-cloud-aws run 38125145738 exhausted RDS from the tick
  function). The tick and backstop schedules gain a `retry_policy`, and their
  functions an `aws_lambda_function_event_invoke_config` (event age 900 and 600
  seconds), so a throttled tick waits instead of being dropped.
  `control_plane_events_reserved_concurrent_executions`, when set, still
  overrides all three.

- `aws-serverless`: every process now also sets
  `Limits__Connections__MaxConcurrentQueries` to its pool cap. With only the
  cap from the previous change, honua-server refused to start
  (`LimitsOptionsValidator`: "Connections.MaxConcurrentQueries must be less
  than or equal to Connections.MaxConnectionPoolSize"; the default is 200), and
  every Lambda failed at init on e2e-cloud-aws run 38116311885. This adds 48
  bytes per Lambda environment; every optional feature at once now leaves 18
  bytes of the 4 KB.

- `aws-serverless`: each server process now caps its PostgreSQL pool so warm
  Lambda instances and GP Batch jobs cannot exhaust a small RDS (e2e-cloud-aws
  run 38107383082 hit `53300: remaining connection slots are reserved`). New
  inputs `lambda_db_max_pool_size` (8), `control_plane_db_max_pool_size` (2),
  `gp_batch_db_max_pool_size` (4) and `db_connection_idle_lifetime_seconds`
  (60) render `Limits__Connections__*` per process. The module-built
  connection string also gains `Maximum Pool Size`, `Connection Idle Lifetime`,
  `Connection Pruning Interval=10` and `Timeout=15`, so its secret value
  changes on upgrade. The cap adds 49 bytes to each Lambda environment; the
  Pro license on top of every other optional feature no longer fits the API
  function either. See the module README, "Database connection budget".

- `aws-serverless`: the control-plane event Lambdas (reconcile, backstop,
  scheduled tick) can read the connection-encryption master-key secret; they
  crashed at init without it. Their role now reads exactly the API Lambda
  role's secret set.
- `aws-serverless`: the GP Batch job definitions take
  `Security__ConnectionEncryption__MasterKey` from the master-key secret
  instead of the admin-password secret, and the job role can read it, so the
  worker can decrypt connection secrets the API stored.
- `aws-serverless`: the RDS security group no longer mixes inline ingress with
  standalone `aws_security_group_rule` resources, which made applies strip
  and re-add the GP Batch and custom-code rules. Its Lambda and
  `db_additional_ingress_cidrs` rules are now standalone
  (`rds_from_lambda`, `rds_from_cidrs`). **Upgrade note:** an existing
  deployment must import those two rule sets before the upgrade apply, or it
  fails with `InvalidPermission.Duplicate`; see the module README's
  "RDS security group rules".

## v0.2.0

Second pinnable release, cut from trunk `8ec0737`. It is a `0.x` **minor**
bump, not a patch: per [`docs/module-versioning.md`](docs/module-versioning.md)
it adds optional inputs and changes defaults that alter apply behaviour.

### Behaviour-changing defaults

- `aws-ecs`, `aws-serverless` and the `aws`, `aws-serverless` and `aws-cert`
  example roots add `licensing_mode` (default `"Disabled"`) and render
  `Licensing__Mode` for the 2026.1 candidate (#192). A deployment that relied
  on the server's implicit licensing mode now starts with licensing disabled;
  set `licensing_mode` (and, for `aws-ecs`, `licensing_edition` plus the
  `pro_license_*` inputs) to keep a licensed deployment.
- `examples/aws`: `enable_postgis` now defaults to `false` so a private RDS
  instance does not require the Terraform runner to reach it (#172). Set it to
  `true` where the runner has database reachability.
- `aws-ecs` and `examples/aws` add `rds_deletion_protection` (default `true`).

### Stricter input validation (an upgrade plan can fail)

Values v0.1.0 accepted can now fail `terraform plan`; check these before
upgrading.

- `aws-serverless`: `admin_password` must now contain uppercase, lowercase,
  digit and special characters in addition to the 32-character minimum (the
  server's Production policy, previously enforced only at cold start). Rotate a
  password that lacks a character class before upgrading.
- `aws-ecs`: `additional_env` and `canary_additional_env` may no longer set
  deployment, file-storage or licensing settings; use the typed variables.
  `licensing_mode`, `licensing_edition`, `pro_license_secret_arn` and
  `pro_license_key_id` are validated.
- `aws-ecs` preconditions now refuse inconsistent or unsafe shapes: partial
  existing-VPC or existing-database inputs, `redis_connection_string` without
  `redis_connection_cidrs`, canary weight/count without `canary_enabled`,
  private-subnet tasks with neither NAT nor public IP, public `0.0.0.0/0`
  ingress without HTTPS, and a Pro license secret without its trusted public
  key (#171).

### aws-ecs

- Added AI provider secret delivery by reference: `ai_provider_secret_arn`,
  `ai_provider_secret_kms_key_arn` (#146).
- Added licensing inputs `licensing_mode`, `licensing_edition`,
  `pro_license_secret_arn`, `pro_license_secret_kms_key_arn`,
  `pro_license_key_id`, `pro_license_trusted_public_key`.
- Added outputs `licensing_mode`, `pro_license_secret_arn`,
  `multi_node_topology_ready`, `alb_health_check`,
  `container_health_check_start_period_seconds`, `deployment_rollback`,
  `task_definition_revision_retention`, `cache_configured`, `database_managed`,
  and a derived protection profile in the operator contract (#184, #193).
- Pinned module and provider sources immutably (#151) and enforced deployment
  safety preconditions (#171).

### aws-serverless

- Added `licensing_mode` (default `"Disabled"`) and `additional_allowed_hosts`
  (default `[]`); added outputs `master_key_secret_arn` and `licensing_mode`.

### aws-ecs, aws-serverless, azure-aca, azure-functions

- Added three optional list inputs, all defaulting to `[]`, for the allowlist
  for request-supplied secret references (honua-server #5055):
  `request_secret_reference_allowed_environment_variables`,
  `request_secret_reference_allowed_environment_variable_prefixes` and
  `request_secret_reference_allowed_secret_reference_prefixes`. Entries render
  as indexed `Security__RequestSecretReferences__*` server settings
  (`aws-serverless` also carries them to the geoprocessing Batch job
  definitions). Empty lists render nothing, so existing deployments plan no
  change and the server's deny-by-default policy is preserved. Server images
  that predate the setting ignore the variables.
- Added `request_secret_reference_secret_arns` and
  `request_secret_reference_kms_key_arns` (`aws-ecs`, `aws-serverless`): the
  server reads an allowlisted `aws:secretsmanager:` reference with its runtime
  role, so these grant read-only access on the ECS task role, the Lambda role
  and the geoprocessing Batch job role. Empty grants nothing.
- `aws-serverless` copies the `additional_env` values the environment
  allowlists permit to the geoprocessing Batch job, so an allowlisted
  `env:NAME` reference resolves there as it does in the Lambda.
- `azure-aca` and `azure-functions` set `AZURE_CLIENT_ID` to the module's
  user-assigned identity when an `azure:` reference is allowlisted, so the
  in-process Key Vault lookup authenticates as that identity.

### examples and tooling

- `examples/aws`: secured remote state and short-lived execution identity for
  exact-plan apply (#158, #174, #202), canonical operator contract v1 (#153),
  2026.1 small presets and AI profiles (#145), and the operator-contract
  identity input `operator_contract_identity`.
- `examples/aws-cert`: bounded Lambda GA certification substrate and bootstrap
  contract (#173, #176, #181, #195).
- `examples/registry-pin` and `docs/module-versioning.md` now pin the released
  `v0.2.0` tag instead of `trunk`.

## v0.1.0

First version-pinnable release of the Honua Terraform modules (tag `v0.1.0`,
commit `cace70f`).

### aws-eks

- Added `cluster_secret_encryption_enabled` (bool, default `true`) and
  `cluster_secret_encryption_key_arn` (string, default `""`). The default is
  unchanged production shape: a module-managed CMK encrypts Kubernetes secrets.
  Ephemeral parity/validation clusters can now set
  `cluster_secret_encryption_enabled = false` so a throwaway cluster does not
  strand a CMK on the 7-day deletion window AWS refuses to shorten, or pass a
  long-lived key ARN to keep the encryption path exercised without minting a key
  per cluster.

### tooling

- Added a scheduled reaper for the AWS infrastructure the manual validation
  workflow strands (`.github/workflows/terraform-validation-infra-reaper.yml` ->
  `infrastructure/terraform/validation/scripts/aws/sweep-orphaned-validation-infra.sh`),
  plus an `if: always()` run-scoped teardown step in the AWS and EKS live jobs
  and a job-summary report of anything left behind. Validation resources now
  also carry a `Stack` tag (`data` | `ecs` | `serverless` | `eks`).
- Added the manual cloud runbook validation procedure
  (`docs/devops/manual-cloud-runbook-validation.md`), a structured evidence
  schema (`docs/devops/cloud-runbook-evidence-template.json`), and an evidence
  capture helper (`scripts/capture-runbook-evidence.sh`).

### Breaking changes

- `aws-ecs`, `azure-aca`, and `azure-functions` now require an explicit,
  nullable `connection_encryption_master_key` input. Set `null` only for a new
  deployment; existing deployments must pass their current key before upgrade.
  This fail-closed contract prevents an omitted input from silently replacing
  the key used to decrypt stored connections.

### aws-ecs

- Initial pinnable release. ECS/Fargate + ALB + RDS PostgreSQL + optional
  ElastiCache Redis.

### azure-aca

- Initial pinnable release. Azure Container Apps + PostgreSQL Flexible Server +
  Key Vault + optional Redis.

### aws-serverless

- Initial pinnable release. Lambda container image + API Gateway HTTP API + RDS.

### azure-functions

- Initial pinnable release. Azure Functions custom container + PostgreSQL
  Flexible Server + optional Redis.

### observability-stack

- Initial pinnable release (Tier 2 add-on). Prometheus + Grafana via Helm. The
  contract for this add-on may move faster than the Tier 1 runtime modules.
