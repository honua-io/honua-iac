# Honua Terraform

Terraform for deploying Honua into customer-owned AWS and Azure environments. GCP is not in scope for this repository.

## Operator path

Choose a stack under `infrastructure/terraform/examples/`, copy `backend.tf.example` and `terraform.tfvars.example`, then apply:

```bash
cp infrastructure/terraform/examples/aws/backend.tf.example \
   infrastructure/terraform/examples/aws/backend.tf
cp infrastructure/terraform/examples/aws/terraform.tfvars.example \
   infrastructure/terraform/examples/aws/terraform.tfvars

terraform -chdir=infrastructure/terraform/examples/aws init
terraform -chdir=infrastructure/terraform/examples/aws plan
terraform -chdir=infrastructure/terraform/examples/aws apply
```

Customer-facing output groups are now split by audience:

- `infrastructure_outputs`: operator-readable endpoints and resource identifiers
- `infrastructure_secrets`: sensitive operator values such as DB or Redis connection material
- `honua_integration_outputs`: Honua control-plane metadata and integration contracts

Detailed guides:

- [docs/operator-deployment.md](docs/operator-deployment.md)
- [docs/operator-state.md](docs/operator-state.md)
- [infrastructure/terraform/README.md](infrastructure/terraform/README.md)

## Customer bundle

To produce a customer-ready distribution without CI internals:

```bash
./scripts/package-customer-terraform.sh
```

This writes `dist/customer-terraform/` with modules, examples, bootstrap templates, and operator docs while excluding GitHub workflows and maintainer validation assets.

## Repository layout

- `infrastructure/terraform/modules/`: reusable Terraform modules
- `infrastructure/terraform/examples/`: deployable stacks and starter configs
- `infrastructure/terraform/bootstrap/`: optional least-privilege identity bootstrap templates
- `infrastructure/terraform/validation/`: maintainer-only integration scripts and runbook helpers
- `.github/workflows/`: CI and live validation workflows

## Maintainer path

For integration/QA validation flows, policy gates, drift checks, and architecture notes:

- [docs/devops/terraform-validation.md](docs/devops/terraform-validation.md)
- [docs/adr/0001-terraform-architecture-refactor.md](docs/adr/0001-terraform-architecture-refactor.md)
- [docs/devops/terraform-architecture-plan.md](docs/devops/terraform-architecture-plan.md)
