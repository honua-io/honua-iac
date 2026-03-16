# Operator Deployment Guide

This guide is for operators deploying Honua into customer-owned AWS or Azure environments. GCP is not supported in this repo.

## Prerequisites

- Terraform 1.8.5+ recommended
- Cloud credentials configured locally
- Container image accessible from the target runtime
- Strong admin and database passwords
- A remote Terraform backend configured before the first shared apply

## Choose a deployment target

- AWS containers: `infrastructure/terraform/examples/aws`
- Azure containers: `infrastructure/terraform/examples/azure`
- AWS serverless: `infrastructure/terraform/examples/aws-serverless`
- Azure serverless: `infrastructure/terraform/examples/azure-functions`
- AWS managed Kubernetes: `infrastructure/terraform/examples/aws-eks`
- Azure managed Kubernetes: `infrastructure/terraform/examples/azure-aks`

## Standard workflow

1. Create backend and stack config:

```bash
cp infrastructure/terraform/examples/<stack>/backend.tf.example \
   infrastructure/terraform/examples/<stack>/backend.tf
cp infrastructure/terraform/examples/<stack>/terraform.tfvars.example \
   infrastructure/terraform/examples/<stack>/terraform.tfvars
```

2. Edit `backend.tf` and `terraform.tfvars`:

- set `honua_admin_password`
- set DB password (`db_password` or `db_admin_password`) when the stack manages data
- set the runtime image (`honua_image` or `honua_image_uri`)
- add mandatory tags such as owner, environment, and cost center
- wire `existing_*` values only when reusing team-managed network/data infrastructure

3. Deploy:

```bash
terraform -chdir=infrastructure/terraform/examples/<stack> init
terraform -chdir=infrastructure/terraform/examples/<stack> plan
terraform -chdir=infrastructure/terraform/examples/<stack> apply
```

4. Verify:

- use `infrastructure_outputs` for URLs and resource identifiers
- use `infrastructure_secrets` for DB or Redis connection material
- use `honua_integration_outputs` only when wiring Honua control-plane automation
- run readiness: `curl -f <public_base_url>/healthz/ready`

5. Destroy when needed:

```bash
terraform -chdir=infrastructure/terraform/examples/<stack> destroy
```

## Recommended defaults

- pin immutable image tags or digests
- keep `enable_postgis = true`
- keep managed databases private unless the runner needs direct reachability
- use remote state and locking from day one
- isolate state by stack and environment rather than relying on workspaces as the primary boundary

## Important PostGIS constraint

AWS ECS, AWS serverless, Azure Container Apps, Azure Functions, and the data-only stacks can enable PostGIS during `terraform apply`. That path uses a `local-exec` provisioner and requires:

- `psql` on the Terraform runner
- network reachability from the Terraform runner to the database endpoint

If your execution environment cannot satisfy that, disable the in-run PostGIS step and enable the extensions through a reachable administrative path after apply.

## Existing infrastructure reuse

Main stacks support reusing network and data resources through `existing_*` inputs. Use this when your platform team provides shared VPCs, subnets, databases, or caches and you want the Honua stack to focus only on compute/runtime concerns.

## Related docs

- `docs/operator-state.md`
- `infrastructure/terraform/README.md`
- `docs/devops/terraform-validation.md`
