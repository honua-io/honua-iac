# Terraform Modules and Stacks

This directory contains reusable modules and deployable stacks for Honua.

## Operator quick start

Choose a stack, create `terraform.tfvars`, then apply.

### AWS ECS/Fargate

```bash
cp infrastructure/terraform/examples/aws/terraform.tfvars.example \
   infrastructure/terraform/examples/aws/terraform.tfvars
terraform -chdir=infrastructure/terraform/examples/aws init
terraform -chdir=infrastructure/terraform/examples/aws plan
terraform -chdir=infrastructure/terraform/examples/aws apply
```

### Azure Container Apps

```bash
cp infrastructure/terraform/examples/azure/terraform.tfvars.example \
   infrastructure/terraform/examples/azure/terraform.tfvars
terraform -chdir=infrastructure/terraform/examples/azure init
terraform -chdir=infrastructure/terraform/examples/azure plan
terraform -chdir=infrastructure/terraform/examples/azure apply
```

### AWS Lambda

```bash
cp infrastructure/terraform/examples/aws-serverless/terraform.tfvars.example \
   infrastructure/terraform/examples/aws-serverless/terraform.tfvars
terraform -chdir=infrastructure/terraform/examples/aws-serverless init
terraform -chdir=infrastructure/terraform/examples/aws-serverless plan
terraform -chdir=infrastructure/terraform/examples/aws-serverless apply
```

### Azure Functions

```bash
cp infrastructure/terraform/examples/azure-functions/terraform.tfvars.example \
   infrastructure/terraform/examples/azure-functions/terraform.tfvars
terraform -chdir=infrastructure/terraform/examples/azure-functions init
terraform -chdir=infrastructure/terraform/examples/azure-functions plan
terraform -chdir=infrastructure/terraform/examples/azure-functions apply
```

Operator guide: `docs/operator-deployment.md`

## Modules

- `modules/aws-ecs` - ECS/Fargate + RDS + ALB
- `modules/azure-aca` - Azure Container Apps + PostgreSQL Flexible Server + Key Vault
- `modules/aws-serverless` - Lambda + API Gateway + RDS
- `modules/azure-functions` - Azure Functions + PostgreSQL Flexible Server
- `modules/aws-eks` - EKS + VPC for managed Kubernetes
- `modules/azure-aks` - AKS for managed Kubernetes
- `modules/observability-stack` - optional Prometheus + Grafana add-on

Module publishing scope and tier classification (Tier 1 publish-candidate,
Tier 3 internal-only) are recorded in [`docs/module-publishing-decision.md`](../../docs/module-publishing-decision.md).

## Examples

- `examples/aws`
- `examples/azure`
- `examples/aws-serverless`
- `examples/azure-functions`
- `examples/aws-eks`
- `examples/azure-aks`
- `examples/observability`

## State backend and execution identity (AWS release lane)

Apply these before the product stack. Backend creation is always a separate,
explicit operation and never a side effect of `terraform init`.

- `bootstrap/aws-tfstate` — S3 remote state: versioning, default encryption,
  public-access denial, HTTPS-only, one exclusive object key per stack and
  environment, the locking primitive, and a least-privilege backend access
  policy.
- `bootstrap/aws-terraform-oidc` — the short-lived **backend access** role.
- `bootstrap/aws-exec-identity` — the short-lived **infrastructure deployment**
  role, with explicit denials that keep it out of the state substrate and out of
  the long-lived-credential business.

See [`docs/operator-state.md`](../../docs/operator-state.md) and
[`docs/devops/terraform-exact-plan-contract.md`](../../docs/devops/terraform-exact-plan-contract.md).

## Bootstrap identities (optional)

- `bootstrap/azure-aca`
- `bootstrap/azure-functions`
- `bootstrap/azure-aks`

Use these when you need dedicated least-privilege deployment identities.

The AWS entries in this family — `bootstrap/aws-ecs`, `bootstrap/aws-serverless`,
and `bootstrap/aws-eks` — create a **long-lived IAM user** and are **local-only
and unsupported for release or certification**. Their `supported_for_release`
output is a hard `false`. Use `bootstrap/aws-exec-identity` for anything shared,
long-lived, or release-bound.

## Validation assets (maintainers)

Validation automation is intentionally isolated from operator deployment stacks under:

- `validation/scripts/aws`
- `validation/scripts/azure`
- `validation/scripts/k8s`
- `validation/scripts/shared`

## Validation and CI (maintainers)

For policy gates, drift checks, and live integration validation, use:

- `./infrastructure/terraform/validation/scripts/shared/terraform-policy-gate.sh`
- `./infrastructure/terraform/validation/scripts/shared/run-terraform-drift-detection.sh`
- `.github/workflows/terraform-manual-validation.yml`
- `docs/devops/terraform-validation.md`
