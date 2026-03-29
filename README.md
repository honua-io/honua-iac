# Honua Terraform

Operator-focused Terraform for deploying Honua in your own AWS or Azure account.

## Deploy Honua (operator path)

1. Choose a target stack:
   - `infrastructure/terraform/examples/aws` (AWS ECS/Fargate)
   - `infrastructure/terraform/examples/azure` (Azure Container Apps)
   - `infrastructure/terraform/examples/aws-serverless` (AWS Lambda)
   - `infrastructure/terraform/examples/azure-functions` (Azure Functions)
2. Copy the stack's `terraform.tfvars.example` to `terraform.tfvars` and fill in secrets/images. If you use remote state, also copy `backend.tf.example` to `backend.tf`.
3. Run apply:

```bash
terraform -chdir=infrastructure/terraform/examples/aws init
terraform -chdir=infrastructure/terraform/examples/aws plan
terraform -chdir=infrastructure/terraform/examples/aws apply
```

4. Capture outputs (`honua_url`, DB endpoint/FQDN) and run health checks.

Detailed guide: [docs/operator-deployment.md](docs/operator-deployment.md)
AWS container-offer plan: [docs/devops/aws-marketplace-container-offer.md](docs/devops/aws-marketplace-container-offer.md)

Marketplace-targeted bundles currently focus on the turnkey container runtimes:
- `infrastructure/terraform/examples/aws`
- `infrastructure/terraform/examples/azure`

The machine-readable bundle matrix lives in `infrastructure/terraform/marketplace/targets.json`.

## Repository layout

- `infrastructure/terraform/modules/`: reusable Terraform modules
- `infrastructure/terraform/examples/`: deployable stacks for each runtime target
- `infrastructure/terraform/bootstrap/`: optional least-privilege identity bootstrap templates
- `infrastructure/terraform/validation/`: maintainer-only validation runner, scenario manifests, compatibility adapters, and runbook helpers
- `.github/workflows/`: Terraform CI and manual validation workflows

## Module docs

- `infrastructure/terraform/modules/aws-ecs/README.md`
- `infrastructure/terraform/modules/azure-aca/README.md`
- `infrastructure/terraform/modules/aws-serverless/README.md`
- `infrastructure/terraform/modules/azure-functions/README.md`
- `infrastructure/terraform/modules/aws-eks/README.md`
- `infrastructure/terraform/modules/azure-aks/README.md`

## Validation and platform QA (maintainer path)

For integration/QA validation flows (policy gates, live applies, drift checks, AKS/EKS paths), use:

- [infrastructure/terraform/README.md](infrastructure/terraform/README.md)
- [docs/devops/terraform-validation.md](docs/devops/terraform-validation.md)
