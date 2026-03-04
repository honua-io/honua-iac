# Operator Deployment Guide

This guide is for platform operators deploying Honua into their own cloud subscriptions/accounts.

## Prerequisites

- Terraform 1.8+
- Cloud credentials configured locally
- Container image accessible from target runtime
- Strong admin and database passwords

## Choose a deployment target

- AWS containers: `infrastructure/terraform/examples/aws`
- Azure containers: `infrastructure/terraform/examples/azure`
- AWS serverless: `infrastructure/terraform/examples/aws-serverless`
- Azure serverless: `infrastructure/terraform/examples/azure-functions`

## Standard workflow

1. Create stack config:

```bash
cp infrastructure/terraform/examples/<stack>/terraform.tfvars.example \
   infrastructure/terraform/examples/<stack>/terraform.tfvars
```

2. Edit `terraform.tfvars`:

- Set `honua_admin_password`
- Set DB password (`db_password` or `db_admin_password`)
- Set container image (`honua_image` or `honua_image_uri`)
- Optionally wire existing DB/Redis/VPC if reusing infra

3. Deploy:

```bash
terraform -chdir=infrastructure/terraform/examples/<stack> init
terraform -chdir=infrastructure/terraform/examples/<stack> plan
terraform -chdir=infrastructure/terraform/examples/<stack> apply
```

4. Verify:

- Read outputs (`honua_url`, DB endpoint/FQDN)
- Run readiness check: `curl -f <honua_url>/healthz/ready`

5. Destroy when needed:

```bash
terraform -chdir=infrastructure/terraform/examples/<stack> destroy
```

## Recommended operator defaults

- Pin versioned images (avoid `latest` in production)
- Keep `enable_postgis = true`
- Keep DB private by default (`db_publicly_accessible = false`)
- Use managed secrets and remote state backend
- Add mandatory tags (owner, env, cost center)

## Existing infrastructure reuse

All main stacks support reusing existing data/network resources via `existing_*` variables.
Use this when your platform team provides shared VPCs, databases, or caches.

## Related docs

- `infrastructure/terraform/README.md` (module and maintainer details)
- `docs/devops/terraform-validation.md` (validation and CI runbook)
