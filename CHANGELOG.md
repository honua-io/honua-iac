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

### tooling

- Added a scheduled reaper for the AWS infrastructure the manual validation
  workflow strands (`.github/workflows/terraform-validation-infra-reaper.yml` ->
  `infrastructure/terraform/validation/scripts/aws/sweep-orphaned-validation-infra.sh`),
  plus an `if: always()` run-scoped teardown step in the AWS and EKS live jobs
  and a job-summary report of anything left behind. Validation resources now
  also carry a `Stack` tag (`data` | `ecs` | `serverless` | `eks`) so a
  run-scoped teardown can reap the throwaway compute stacks without destroying
  a data stack `--keep-data` was told to retain. No module inputs or outputs
  changed.
- Added the manual cloud runbook validation procedure
  (`docs/devops/manual-cloud-runbook-validation.md`), a structured evidence
  schema (`docs/devops/cloud-runbook-evidence-template.json`), and an evidence
  capture helper (`scripts/capture-runbook-evidence.sh` ->
  `infrastructure/terraform/validation/scripts/shared/capture-runbook-evidence.sh`)
  for recording apply -> smoke -> destroy beta-validation evidence across the
  AWS/Azure AOT and JIT matrix. No module inputs or outputs changed.

### aws-eks

- Added `cluster_secret_encryption_enabled` (bool, default `true`) and
  `cluster_secret_encryption_key_arn` (string, default `""`). The default is
  unchanged production shape: a module-managed CMK encrypts Kubernetes secrets.
  Ephemeral parity/validation clusters can now set
  `cluster_secret_encryption_enabled = false` so a throwaway cluster does not
  strand a CMK on the 7-day deletion window AWS refuses to shorten, or pass a
  long-lived key ARN to keep the encryption path exercised without minting a key
  per cluster.

## v0.1.0 (planned — not yet tagged)

Prepared notes for the first version-pinnable release of the Honua Terraform
modules. These notes are staged so the release can be cut with a single tag
push; until `git tag v0.1.0 && git push origin v0.1.0` is run (see the release
process in [`docs/module-versioning.md`](docs/module-versioning.md)), no
`v0.1.0` tag exists, so `?ref=v0.1.0` will not resolve — pin `?ref=trunk` in the
meantime.

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
