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

No changes yet.

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
