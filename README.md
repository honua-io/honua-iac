# Honua Terraform

Operator-focused Terraform for deploying Honua in your own AWS or Azure account.

This repository was named `honua-terraform` until it was renamed to `honua-iac`;
GitHub redirects the old name and old clone URLs here, so no separate archive
exists.

Current infrastructure capabilities are summarized in [docs/features/README.md](docs/features/README.md).

## Deploy Honua (operator path)

1. Choose a target stack. The qualified 2026.1 targets are the two AWS stacks.
   Studio, mixed ECS+Batch, EKS, multi-tenancy, and Helm are outside that
   scope. Azure is preview and is not qualified.
   - `infrastructure/terraform/examples/aws` (AWS ECS/Fargate) — qualified 2026.1 target
   - `infrastructure/terraform/examples/aws-serverless` (AWS Lambda) — qualified 2026.1 target
   - `infrastructure/terraform/examples/azure` (Azure Container Apps) — preview, not a qualified 2026.1 target
   - `infrastructure/terraform/examples/azure-functions` (Azure Functions) — preview, not a qualified 2026.1 target
2. Copy the stack's `terraform.tfvars.example` to `terraform.tfvars` and fill in secrets/images.
3. For a single-node development cell, add the stack's non-secret `small`
   overlay from `presets/small.tfvars.example`.
4. Run plan before apply:

```bash
terraform -chdir=infrastructure/terraform/examples/aws init
terraform -chdir=infrastructure/terraform/examples/aws plan \
  -var-file=presets/small.tfvars.example
terraform -chdir=infrastructure/terraform/examples/aws apply \
  -var-file=presets/small.tfvars.example
```

5. Capture outputs (`honua_url`, DB endpoint/FQDN) and run health checks.

Detailed guide: [docs/operator-deployment.md](docs/operator-deployment.md).
Preset contract: [docs/deployment-presets.md](docs/deployment-presets.md).

## Agent deploy identity (AWS)

Once the cell shape is known, Terraform runs as a least-privilege, short-lived
role. The agent does not need IAM-admin, and it cannot widen that role.

1. The agent proposes a topology: `compute` of `ecs`, `eks`, or `lambda`, plus
   the optional flags `redis`, `custom_domain`, `waf`, and `gp_batch`.
2. An administrator approves that shape and applies `bootstrap/aws-exec-identity`
   with it. This is the only step that needs an identity allowed to create the
   deployment role.
3. The agent assumes only the role this root created
   (`deploy_identity_contract.role_arn`). The session is short-lived STS.
4. The agent applies the cell with that session. The role's allow-list is the
   union of the action manifests for the approved topology, and nothing else.

`deploy_identity_contract` is the document the agent can show: the topology,
the role ARN, the exact actions by service, and what the role cannot do
(state bucket, long-lived credentials, passing itself, and every feature that
was not approved).

## Operator contract (automation handoff)

Certified stacks emit `deployment_contract`, `validation_contract`, and
`operations_contract` — the versioned `honua.operator-contract/v2` handoff that
honua-devops, honua-server, and honua-release consume instead of scraping
scalar outputs. The scalar outputs remain but are non-authoritative.

Schema, field semantics, sensitivity rules, canonicalization/digest rules,
compatibility policy, and producer/consumer ownership:
[docs/operator-contract.md](docs/operator-contract.md).

```bash
terraform -chdir=infrastructure/terraform/examples/aws output -json > contract.json
./scripts/validate-operator-contract.sh --require-qualified contract.json
```

## Repository layout

- `infrastructure/terraform/modules/`: reusable Terraform modules
- `infrastructure/terraform/examples/`: deployable stacks for each runtime target
- `infrastructure/terraform/bootstrap/`: optional least-privilege identity bootstrap templates
- `infrastructure/terraform/validation/`: maintainer-only integration scripts and runbook helpers
- `.github/workflows/`: Terraform CI and manual validation workflows

## Module docs

- `modules/aws-ecs/README.md`
- `modules/azure-aca/README.md`
- `modules/aws-serverless/README.md`
- `modules/azure-functions/README.md`
- `modules/aws-eks/README.md`
- `modules/azure-aks/README.md`

## Validation and platform QA (maintainer path)

For integration/QA validation flows (policy gates, live applies, drift checks, AKS/EKS paths), use:

- [infrastructure/terraform/README.md](infrastructure/terraform/README.md)
- [docs/devops/terraform-validation.md](docs/devops/terraform-validation.md)

## Beta cloud validation

Apply -> smoke -> destroy runbook execution and structured evidence capture for
beta sign-off across the AWS/Azure AOT and JIT matrix:

- [docs/devops/manual-cloud-runbook-validation.md](docs/devops/manual-cloud-runbook-validation.md)

## AWS certification live evidence

The ordered commands to take a disposable AWS account from zero to the live
evidence honua-iac#118 requires, and back to zero — bootstrap, the four-role
separation, governed plan/apply, IAM allow/deny proofs, lock-contention
refusals, teardown, and a cost estimate:

- [docs/devops/aws-cert-live-evidence-runbook.md](docs/devops/aws-cert-live-evidence-runbook.md)

## Disaster-recovery drills

Backup/restore and failover drill runbooks with RTO/RPO evidence capture:

- [docs/devops/backup-restore-runbook.md](docs/devops/backup-restore-runbook.md)
- [docs/devops/failover-drill-runbook.md](docs/devops/failover-drill-runbook.md)

## Documentation

- **[Full documentation index](docs/SUMMARY.md)** — every published page, generated from the documentation bundle so it cannot drift.

## Module publishing scope

Decision and tier classification: [docs/module-publishing-decision.md](docs/module-publishing-decision.md).
