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

## Horizontal scaling contract

The ECS and Container Apps stacks default to one server task/replica and
`Deployment__Mode=SingleInstance`. Their Terraform modules fail the plan before
deployment if the configured scaling ceiling can exceed one without all of the
MultiNode prerequisites:

- `deployment_mode = "MultiNode"`;
- a provisioned or existing Redis connection; and
- shared cloud file storage: `AwsS3` with an existing bucket for ECS, or
  `AzureBlob` with an existing storage connection string and container for ACA.

The modules wire these values into Honua's runtime configuration. The AWS module
also grants its ECS task role least-privilege access to the named bucket. The
Azure module keeps the supplied storage connection string in Key Vault. Neither
module creates the shared file-storage bucket/container, so provision it before
enabling horizontal scaling.

Treat these settings as one topology change. Do not place
`Deployment__Mode` or the module-managed `FileStorage__*` keys in
`additional_env`; use the typed inputs so Terraform can validate the topology.

## Consuming modules at a pinned version

Operators who template their own root module (instead of using the in-repo
`examples/*` stacks) can pin a Honua module to a released version via Git source:

```hcl
module "honua" {
  source = "git::https://github.com/honua-io/honua-iac.git//infrastructure/terraform/modules/aws-ecs?ref=v0.1.0"
  # ...module inputs...
}
```

Swap `aws-ecs` for any Tier 1 / Tier 2 module and `v0.1.0` for the tag you want.
Run `terraform init` (or `terraform init -upgrade` to move to a newer tag). A
ready-to-copy example lives at
`infrastructure/terraform/examples/registry-pin/`.

Modules are not published to the public Terraform Registry: the Honua repos are
licensed under the Elastic License 2.0 (ELv2), which the public registry does
not permit. ELv2 still applies to consumers who pull modules via Git source. See
[`module-versioning.md`](module-versioning.md) and
[`module-publishing-decision.md`](module-publishing-decision.md) for the full
distribution policy.

## Existing infrastructure reuse

All main stacks support reusing existing data/network resources via `existing_*` variables.
Use this when your platform team provides shared VPCs, databases, or caches.

## Related docs

- `infrastructure/terraform/README.md` (module and maintainer details)
- `docs/devops/terraform-validation.md` (validation and CI runbook)
