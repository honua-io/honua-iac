# Deployment presets

The four primary deployable roots ship a `small` infrastructure preset for a
single-node development cell:

| Target | Terraform root | Preset behavior | Serving units |
| --- | --- | --- | --- |
| AWS ECS/Fargate (`aws-ecs`) | `infrastructure/terraform/examples/aws` | One ECS task, one-task scaling ceiling, Redis on, no canary, development ALB retention settings | 1 |
| Azure Container Apps (`azure-aca`) | `infrastructure/terraform/examples/azure` | One replica, one-replica scaling ceiling, Redis on, locally redundant development backup posture | 1 |
| AWS Lambda (`aws-serverless`) | `infrastructure/terraform/examples/aws-serverless` | Core Lambda cell, Redis on, optional dashboards/tracing/event worker off | 1 |
| Azure Functions (`azure-functions`) | `infrastructure/terraform/examples/azure-functions` | One EP1 container plan, Redis on, deployment slot off, locally redundant development backup posture | 1 |

The target names in parentheses are module or operator names. The paths in the
second column are the actual deployable roots; for example, `aws-ecs` maps to
the `examples/aws` root. Every `small` preset provisions a single serving unit —
see [Infrastructure size versus capability profile](#infrastructure-size-versus-capability-profile)
for what that means for the server's separate deployment profile.

## Two files per stack

Each of the four roots ships two committed inputs with different jobs:

| File | Contents | Committed secrets |
| --- | --- | --- |
| `terraform.tfvars.example` | Every variable the root requires, plus production-shaped defaults | None — placeholders only |
| `presets/small.tfvars.example` | Non-secret size overrides for a development cell | None by construction |

The root example is the starting point and is the only one of the two that is
complete on its own: copy it to `terraform.tfvars`, replace the placeholders,
and the stack plans. The preset is an overlay, never a replacement — it
deliberately omits the image and secrets so it can stay committed and non-secret.

Terraform applies `terraform.tfvars` first and then each `-var-file` in the order
given, so the preset wins for every variable it sets. It wins outright: a
`-var-file` value **replaces** the earlier value rather than merging into it, so
the preset's `tags` block substitutes for the one in `terraform.tfvars` instead
of adding to it. Two keys overlap today: `environment`, where a scalar override
is the whole point, and `tags`, where the replacement is easy to miss. Keep the
two tag blocks in agreement, or delete the preset's `tags` block to keep your own.

`./scripts/check-tfvars-examples.sh` enforces this contract in CI: it fails if a
root example stops assigning a required variable, if either file sets a variable
the root no longer declares, and it prints the overlapping keys for review.
`terraform validate` cannot catch any of that, because validate never reads a
tfvars file.

## Use a preset

Keep credentials in the stack-local, gitignored `terraform.tfvars` or supply
them through `TF_VAR_*` environment variables. The preset is a separate,
non-secret overlay:

```bash
stack=aws
cp infrastructure/terraform/examples/$stack/terraform.tfvars.example \
  infrastructure/terraform/examples/$stack/terraform.tfvars
# Replace the image and secret placeholders in terraform.tfvars.

terraform -chdir=infrastructure/terraform/examples/$stack init
terraform -chdir=infrastructure/terraform/examples/$stack plan \
  -var-file=presets/small.tfvars.example
```

The committed examples contain conspicuous placeholders so a copied file has
all required inputs and reaches Terraform validation. They are not secret-store
references: Terraform passes these values to the module literally. Never put a
real secret in a committed preset or example. For automation, resolve the
secret outside Terraform and expose it only to the process, for example as
`TF_VAR_honua_admin_password`.

Before an apply, configure a remote backend suitable for the cloud and
environment. Do not use local state for a shared or long-lived cell: Terraform
state contains infrastructure metadata and can contain sensitive values.

### Terraform version

Use a Terraform version that satisfies the roots' declared constraint:
`required_version = ">= 1.5, < 2.0"`. CI validates the primary operator roots
and the optional connection-encryption master-key flow on Terraform 1.5 as well
as on the current Terraform release.

## Infrastructure size versus capability profile

`small` controls only the cloud footprint. It does not enable server routes,
grant a license, or choose Honua capabilities. Those come from the server's
separate capability deployment profile, documented in honua-server at
[`docs/guides/deploy/capability-deployment-profiles.md`](https://github.com/honua-io/honua-server/blob/trunk/docs/guides/deploy/capability-deployment-profiles.md).
Generate the profile from the canonical capability keys, then pass its non-secret
environment settings to the deployed server:

```bash
# in a honua-server checkout
python scripts/deployment/generate-capability-profile.py \
  --caps serve.wfs,ops.health \
  --serving-units 1 \
  --format env
```

The two decisions line up at exactly one point: `--serving-units`. Each `small`
preset provisions a single serving unit, which is the bottom of the profile
generator's `Starter` band (up to 3 units). Nothing else is shared — the
capability keys you select are independent of which of the four roots you
deployed, and the profile never emits a license or an edition grant. If you
change the preset's replica or task counts, restate `--serving-units` to match;
Terraform will not do it for you.

Keep the `profileFingerprint` with the Terraform plan evidence so the requested
feature surface and the infrastructure size stay independently reviewable.

The preset is intentionally limited to development. Production sizing depends
on workload, availability, retention, and recovery requirements; review the
root variables and module documentation instead of promoting this preset
unchanged.
