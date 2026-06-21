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

- Added the manual cloud runbook validation procedure
  (`docs/devops/manual-cloud-runbook-validation.md`), a structured evidence
  schema (`docs/devops/cloud-runbook-evidence-template.json`), and an evidence
  capture helper (`scripts/capture-runbook-evidence.sh` ->
  `infrastructure/terraform/validation/scripts/shared/capture-runbook-evidence.sh`)
  for recording apply -> smoke -> destroy beta-validation evidence across the
  AWS/Azure AOT and JIT matrix. No module inputs or outputs changed.

## v0.1.0

First tagged, version-pinnable release of the Honua Terraform modules. No module
inputs or outputs changed in this release; the tag exists so external consumers
can pin a Git-source `ref`.

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
