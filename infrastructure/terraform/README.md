# Terraform Modules and Stacks

This directory contains the customer deployment surface for Honua plus the maintainer validation assets that exercise it.

## Supported scope

- Clouds: AWS and Azure
- Runtimes: containers, serverless, and managed Kubernetes
- Data-only stacks: AWS and Azure
- Optional observability add-on: Kubernetes/Helm

GCP is intentionally out of scope.

## Operator quick start

Each example stack now ships with:

- `backend.tf.example`
- `terraform.tfvars.example`
- customer-facing grouped outputs

Typical flow:

```bash
cp infrastructure/terraform/examples/aws/backend.tf.example \
   infrastructure/terraform/examples/aws/backend.tf
cp infrastructure/terraform/examples/aws/terraform.tfvars.example \
   infrastructure/terraform/examples/aws/terraform.tfvars

terraform -chdir=infrastructure/terraform/examples/aws init
terraform -chdir=infrastructure/terraform/examples/aws plan
terraform -chdir=infrastructure/terraform/examples/aws apply
```

Customer output groups:

- `infrastructure_outputs`: non-sensitive endpoints and resource identifiers
- `infrastructure_secrets`: sensitive DB/Redis values
- `honua_integration_outputs`: control-plane metadata and contracts consumed by Honua automation

Provider versioning policy:

- modules stay compatibility-oriented
- example stacks pin to the tested provider minor line for safer customer upgrades

Operator guides:

- `docs/operator-deployment.md`
- `docs/operator-state.md`

## Modules

- `modules/aws-ecs`
- `modules/aws-serverless`
- `modules/aws-data`
- `modules/aws-eks`
- `modules/azure-aca`
- `modules/azure-functions`
- `modules/azure-data`
- `modules/azure-aks`
- `modules/observability-stack`

## Examples

- `examples/aws`
- `examples/aws-serverless`
- `examples/aws-data`
- `examples/aws-eks`
- `examples/azure`
- `examples/azure-functions`
- `examples/azure-data`
- `examples/azure-aks`
- `examples/observability`

## Bootstrap identities

- `bootstrap/aws-ecs`
- `bootstrap/aws-serverless`
- `bootstrap/aws-eks`
- `bootstrap/azure-aca`
- `bootstrap/azure-functions`
- `bootstrap/azure-aks`

Use these when you need dedicated least-privilege deployment identities.

## Fast feedback

Static validation now has two layers:

- `terraform validate` for configuration integrity
- `terraform test` for fast contract and variable-validation coverage without live cloud credentials

## Customer packaging

To produce a clean customer distribution:

```bash
./scripts/package-customer-terraform.sh
```

This creates `dist/customer-terraform/` with modules, examples, bootstrap templates, and operator docs only.

## Maintainer validation assets

Validation automation is isolated from the operator surface under:

- `validation/scripts/aws`
- `validation/scripts/azure`
- `validation/scripts/k8s`
- `validation/scripts/shared`

For policy gates, drift checks, and live integration validation, use:

- `./infrastructure/terraform/validation/scripts/shared/terraform-policy-gate.sh`
- `./infrastructure/terraform/validation/scripts/shared/run-terraform-drift-detection.sh`
- `.github/workflows/terraform-ci.yml`
- `.github/workflows/terraform-manual-validation.yml`
- `docs/devops/terraform-validation.md`
