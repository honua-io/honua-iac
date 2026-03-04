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

## Examples

- `examples/aws`
- `examples/azure`
- `examples/aws-serverless`
- `examples/azure-functions`
- `examples/aws-eks`
- `examples/azure-aks`
- `examples/observability`

## Bootstrap identities (optional)

- `bootstrap/aws-ecs`
- `bootstrap/aws-serverless`
- `bootstrap/aws-eks`
- `bootstrap/azure-aca`
- `bootstrap/azure-functions`
- `bootstrap/azure-aks`

Use these when you need dedicated least-privilege deployment identities.

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
