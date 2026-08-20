# Honua Terraform

Operator-focused Terraform for deploying Honua in your own AWS or Azure account.

Current infrastructure capabilities are summarized in [docs/features/README.md](docs/features/README.md).

## Deploy Honua (operator path)

1. Choose a target stack:
   - `infrastructure/terraform/examples/aws` (AWS ECS/Fargate)
   - `infrastructure/terraform/examples/azure` (Azure Container Apps)
   - `infrastructure/terraform/examples/aws-serverless` (AWS Lambda)
   - `infrastructure/terraform/examples/azure-functions` (Azure Functions)
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

## Disaster-recovery drills

Backup/restore and failover drill runbooks with RTO/RPO evidence capture:

- [docs/devops/backup-restore-runbook.md](docs/devops/backup-restore-runbook.md)
- [docs/devops/failover-drill-runbook.md](docs/devops/failover-drill-runbook.md)

## Module publishing scope

Decision and tier classification: [docs/module-publishing-decision.md](docs/module-publishing-decision.md).
