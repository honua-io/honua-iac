# Terraform Modules and Stacks

This directory contains the deployable Terraform roots, reusable modules, bootstrap identity templates, and maintainer validation assets for Honua.

## Start Here

- Operators: `../../docs/operator-deployment.md`
- AWS Marketplace container-offer work: `../../docs/devops/aws-marketplace-container-offer.md`
- Validation and CI maintainers: `../../docs/devops/terraform-validation.md`
- Validation runner internals: `validation/runner/README.md`

## Repository Layout

### Deployable runtime roots

- `examples/aws` - AWS ECS/Fargate runtime
- `examples/aws-serverless` - AWS Lambda/API Gateway runtime
- `examples/azure` - Azure Container Apps runtime
- `examples/azure-functions` - Azure Functions runtime
- `examples/aws-eks` - EKS cluster root
- `examples/azure-aks` - AKS cluster root

### Support roots

- `examples/aws-data` - shared AWS data services for validation/reuse
- `examples/azure-data` - shared Azure data services for validation/reuse
- `examples/observability` - Prometheus + Grafana add-on for Kubernetes scenarios

### Reusable modules

- `modules/aws-ecs`
- `modules/aws-serverless`
- `modules/azure-aca`
- `modules/azure-functions`
- `modules/aws-eks`
- `modules/azure-aks`
- `modules/observability-stack`

### Bootstrap identities

- `bootstrap/aws-ecs`
- `bootstrap/aws-serverless`
- `bootstrap/aws-eks`
- `bootstrap/azure-aca`
- `bootstrap/azure-functions`
- `bootstrap/azure-aks`

### Validation assets

- `validation/scenarios` - declarative scenario manifests
- `validation/runner/Honua.TerraformValidation.Runner` - `.NET 10` validation runner
- `validation/adapters/*` - stable wrapper boundary for validation entrypoints
- `validation/scripts/*` - private shell implementation layer retained where scenarios are not yet fully runner-native

## Runtime Selection

| Need | Recommended root | Marketplace bundle status |
|---|---|---|
| Long-running HTTP service on AWS | `examples/aws` | AWS current |
| Serverless HTTP on AWS | `examples/aws-serverless` | No |
| Managed container app on Azure | `examples/azure` | Repo metadata only |
| Serverless custom container on Azure | `examples/azure-functions` | No |
| Managed Kubernetes on AWS | `examples/aws-eks` | No |
| Managed Kubernetes on Azure | `examples/azure-aks` | No |

This column reflects current repo bundle positioning, not equivalent seller-portal readiness across
all clouds. External marketplace submission work is currently AWS-first.

## Minimal Operator Workflow

```bash
cp infrastructure/terraform/examples/<stack>/terraform.tfvars.example \
  infrastructure/terraform/examples/<stack>/terraform.tfvars

terraform -chdir=infrastructure/terraform/examples/<stack> init
terraform -chdir=infrastructure/terraform/examples/<stack> plan
terraform -chdir=infrastructure/terraform/examples/<stack> apply
```

If you use remote state, also copy `infrastructure/terraform/examples/<stack>/backend.tf.example` to `backend.tf` before `terraform init`.

Deployable runtime roots now expose a provider-neutral `install` input surface and emit normalized
`install_contract` and `deploy_contract` outputs for bundle automation. They also emit
`deployment_contract`, `validation_contract`, and `operations_contract` outputs for deploy,
scenario, and day-2 automation. The detailed operator procedures, cross-cloud comparison, registry
guidance, backup/restore, and credential rotation steps live in `docs/operator-deployment.md`.
Marketplace-targeted bundle metadata lives under `infrastructure/terraform/marketplace/`.

Example-root output conventions:

- `install_contract`: provider-neutral questionnaire surface after local fallback/default resolution
- `deploy_contract`: normalized control-plane handoff emitted by the runtime module
- `deployment_contract`: root-level bundle describing endpoints, rollout target, and dependencies
- `validation_contract`: stable scenario metadata for smoke/load/idempotency automation
- `operations_contract`: structured backup/restore, secret-store, and grouping metadata

## Validation Boundary

The validation stack has two user-facing entry layers:

- GitHub Actions workflows call the `.NET 10` runner directly.
- Stable shell entrypoints under `scripts/` and `validation/adapters/` exist for compatibility.

The current split is:

- `static-validate`, `policy-gates`, `drift`, `k8s-live`, `aks-live`, `eks-live`, `azure-live`, and `aws-live` are all orchestrated by the `.NET 10` runner.
- `scripts/` and `validation/adapters/` remain stable compatibility entrypoints for humans and older CI glue.
- The only intentional script execution still on the live path is the optional external `honua-server` post-apply platform suite.
