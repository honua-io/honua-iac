# Terraform Bootstrap Service Accounts

This directory contains least-privilege **service account templates** for running Honua's
Terraform modules. Separate templates are provided for ECS/Fargate vs serverless runtimes, and
for AWS vs Azure.

## Templates
- `aws-ecs` — IAM user + policy for the ECS/Fargate + RDS + ALB module.
- `aws-serverless` — IAM user + policy for Lambda/API Gateway style deployments.
- `azure-aca` — Azure AD service principal + custom role for Azure Container Apps.
- `azure-functions` — Azure AD service principal + custom role for Azure Functions.

## Support access
- `aws-support-access` — cross-account, key-free `HonuaSupportObserveRole`
  (read-only diagnostics) and `HonuaSupportBreakGlassRole` (short-lived,
  permissions-boundary-capped remediation) for granting Honua scoped,
  ticket-bounded support access. See its `README.md` for the operator workflow
  (approve -> assume -> diagnose/fix -> expire/revoke).
- `azure-support-access` — least-privilege custom RBAC roles `Honua Support
  Observe` (read-only diagnostics) and `Honua Support Break-Glass` (short-lived,
  narrower-than-Contributor remediation) for granting Honua scoped, ticket-bounded
  support access. Observe is a standing read-only assignment; break-glass is
  time-bounded via Entra PIM activation per ticket. See its `README.md` for the
  operator workflow (approve -> activate -> diagnose/fix -> expire/revoke) and the
  Terraform-vs-PIM automation boundary.

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

Each template outputs the credentials (or client secret) needed by your CI or local Terraform
runs. Treat these as secrets.
