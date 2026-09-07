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

For a disposable, single-node development cell, keep secrets in
`terraform.tfvars` and add the committed non-secret preset to both plan and
apply:

```bash
terraform -chdir=infrastructure/terraform/examples/<stack> init
terraform -chdir=infrastructure/terraform/examples/<stack> plan \
  -var-file=presets/small.tfvars.example
terraform -chdir=infrastructure/terraform/examples/<stack> apply \
  -var-file=presets/small.tfvars.example
```

See [deployment-presets.md](deployment-presets.md) for the exact target-to-root
mapping, secret handling, and the distinction between infrastructure size and
the server capability deployment profile.

3. Deploy without a preset when you have supplied an environment-specific size:

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

The AWS ECS root enables ALB and production RDS deletion protection by
default. Before destroying that root, make a separate approved apply with
both protections disabled, then generate a fresh destroy plan:

```bash
terraform -chdir=infrastructure/terraform/examples/aws apply \
  -var='alb_deletion_protection=false' \
  -var='rds_deletion_protection=false'
terraform -chdir=infrastructure/terraform/examples/aws destroy
```

Changing protection spends any previously generated plan; do not reuse it.

## Governed AWS deployment (remote state + short-lived identity)

The workflow above is the disposable-development path: local state, whatever
credentials your shell happens to hold, and a plan that is regenerated at apply
time. That is fine for an account you own and will delete. It is **not** the path
for anything shared, long-lived, or release-bound.

For those, three things change:

1. **Remote state, created separately.** Apply `bootstrap/aws-tfstate` on its own,
   then copy the stack's `backend.tf.example` to `backend.tf`. Backend creation is
   never a side effect of `terraform init`.
2. **A short-lived deployment identity.** Apply `bootstrap/aws-terraform-oidc`
   (backend access) and `bootstrap/aws-exec-identity` (infrastructure deployment).
   No IAM user, no access key. `bootstrap/aws-ecs`, `bootstrap/aws-serverless`,
   and `bootstrap/aws-eks` create long-lived IAM users and are local-only and
   unsupported for release.
3. **One exact saved plan.** Produce the plan and its approval digest once, then
   apply exactly those bytes:

```bash
scripts/terraform-exact-plan.sh \
  --root infrastructure/terraform/examples/aws \
  --action apply --plan-out out/honua.tfplan \
  --actor "operator:you@example.com"

scripts/terraform-exact-apply.sh \
  --plan out/honua.tfplan --receipt-out out/receipt.json
```

The apply wrapper refuses before touching anything if the account, role, backend,
workspace, provider lock, IaC revision, inputs, or state lineage moved since the
plan, if the plan expired, or if it was already applied. Full field and refusal
reference: [`docs/devops/terraform-exact-plan-contract.md`](devops/terraform-exact-plan-contract.md)
and [`docs/operator-state.md`](operator-state.md).

## Recommended operator defaults

- Pin versioned images (avoid `latest` in production)
- The `examples/aws` root defaults to `enable_postgis = false` because the
  database is private by default. Set it to `true` only when the Terraform
  runner can reach PostgreSQL. The ECS module bootstraps PostGIS with local
  `psql`, so a private
  RDS endpoint cannot be bootstrapped from a normal laptop or external CI
  runner. Use an in-VPC bootstrap first, or temporarily set
  `db_publicly_accessible=true` with narrowly scoped
  `db_additional_ingress_cidrs` for the bootstrap apply.
- Keep DB private by default (`db_publicly_accessible = false`)
- Use managed secrets and a remote state backend (mandatory for anything shared
  or long-lived; see [`operator-state.md`](operator-state.md))
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
  source = "git::https://github.com/honua-io/honua-iac.git//infrastructure/terraform/modules/aws-ecs?ref=trunk"
  connection_encryption_master_key = null # New deployments only; upgrades must supply the current key
  # ...module inputs...
}
```

Swap `aws-ecs` for any Tier 1 / Tier 2 module. After the first release, replace
`trunk` with a tag that contains the required connection-key input.
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
