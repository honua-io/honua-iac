# Terraform Bootstrap Service Accounts

This directory contains least-privilege **service account templates** for running Honua's
Terraform modules. Separate templates are provided for ECS/Fargate vs serverless runtimes, and
for AWS vs Azure.

## Templates
- `aws-ecs` — IAM user + policy for the ECS/Fargate + RDS + ALB module.
- `aws-serverless` — IAM user + policy for Lambda/API Gateway style deployments.
- `aws-eks` — IAM user + policy for the EKS module.

The three AWS IAM-user templates are local-only and deprecated for new cells.
Use [`aws-exec-identity`](aws-exec-identity/README.md) with a `topology` object
instead: an administrator applies that short-lived role, and the agent assumes
only that role. Their IAM grants stay confined to the deployed stack's name
prefix, every role they create must carry the workload permissions boundary
they emit, and `iam:PassRole` is limited to the services each stack uses. See
each template's `README.md` ("IAM scope"). Do not delete the templates; existing
local accounts still plan with them.
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
> including database (RDS/Postgres) and Redis where applicable. The certified
> `aws-exec-identity` role drops ElastiCache, ACM, Route 53, WAFv2, and Batch
> unless the approved `topology` turns that feature on. Do not hand-edit those
> actions out of the long-lived templates for a release account; apply the
> short-lived role with the matching flags instead.

## Usage
Each template is a standalone Terraform project. Example:

```bash
cd infrastructure/terraform/bootstrap/aws-ecs
terraform init
terraform apply
```

Each template outputs the credentials (or client secret) needed by your CI or local Terraform
runs. Treat these as secrets.
