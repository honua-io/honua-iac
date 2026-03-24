# Terraform Bootstrap Service Accounts

This directory contains least-privilege bootstrap identity templates for running Honua's Terraform
modules. Separate templates are provided for ECS/Fargate vs serverless runtimes, and for AWS vs
Azure.

## Templates
- `aws-ecs` — IAM policy surface for ECS/Fargate + RDS + ALB deployments, with OIDC federation
  preferred and IAM user/access key fallback available.
- `aws-serverless` — IAM policy surface for Lambda/API Gateway style deployments, with OIDC
  federation preferred and IAM user/access key fallback available.
- `azure-aca` — Microsoft Entra application + custom role for Azure Container Apps, with workload
  identity federation preferred and client-secret fallback available.
- `azure-functions` — Microsoft Entra application + custom role for Azure Functions, with workload
  identity federation preferred and client-secret fallback available.
- `aws-eks` and `azure-aks` follow the same pattern for managed-cluster bootstrap.

> These are least-privilege *starting points* scoped to the services used by each template,
> including database (RDS/Postgres) and Redis where applicable. If you disable optional
> features (WAF, Route53, ACM, etc.) you can remove the related permissions. If you add new
> components, expand the policy accordingly.

## Usage
Each template is a standalone Terraform project. Example:

```bash
cd infrastructure/terraform/bootstrap/aws-ecs
terraform init
terraform apply
```

Each template emits a machine-readable `bootstrap_identity_contract` output. Prefer the
federated/workload identity mode for CI and marketplace automation. Static access keys or client
secrets are intentionally fallback surfaces for validation or environments that cannot yet use
federation.
