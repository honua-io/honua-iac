# Deployment presets

The four primary deployable roots ship a `small` infrastructure preset for a
single-node development cell:

| Target | Terraform root | Preset behavior |
| --- | --- | --- |
| AWS ECS/Fargate (`aws-ecs`) | `infrastructure/terraform/examples/aws` | One ECS task, one-task scaling ceiling, Redis on, no canary, development ALB retention settings |
| Azure Container Apps (`azure-aca`) | `infrastructure/terraform/examples/azure` | One replica, one-replica scaling ceiling, Redis on, locally redundant development backup posture |
| AWS Lambda (`aws-serverless`) | `infrastructure/terraform/examples/aws-serverless` | Core Lambda cell, Redis on, optional dashboards/tracing/event worker off |
| Azure Functions (`azure-functions`) | `infrastructure/terraform/examples/azure-functions` | One EP1 container plan, Redis on, deployment slot off, locally redundant development backup posture |

The target names in parentheses are module or operator names. The paths in the
middle column are the actual deployable roots; for example, `aws-ecs` maps to
the `examples/aws` root.

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

## Infrastructure size versus capability profile

`small` controls only the cloud footprint. It does not enable server routes,
grant a license, or choose Honua capabilities. Generate the server's separate
capability deployment profile from the canonical capability keys, then pass its
non-secret environment settings to the deployed server. Keep the profile
fingerprint with the Terraform plan evidence so the requested feature surface
and the infrastructure size remain independently reviewable.

The preset is intentionally limited to development. Production sizing depends
on workload, availability, retention, and recovery requirements; review the
root variables and module documentation instead of promoting this preset
unchanged.

## AI control-plane profiles

Every primary cloud root enables the same 2026.1 MCP profile contract in the
Honua container or function environment:

| Profile | Configuration | Required catalog proof |
| --- | --- | --- |
| Admin | Published by the default admin operation family; no optional profile flag | `tools/list` contains the `honua_admin_*` operation family, including `honua_admin_server_status` |
| Analysis | `Mcp__Profiles__1=analysis` | `honua_buffer_features`, `honua_overlay_features`, `honua_summarize_statistics`, `honua_reproject_features`, `honua_join_features`, `honua_export_dataset` |
| Esri GP | `Mcp__Profiles__2=esri-gp` | `honua_esri_gp_list_tasks`, `honua_esri_gp_describe_task`, `honua_esri_gp_execute_task` |

`Mcp__Profiles__0=base` remains the common data-access profile. The Esri GP
profile is the AI-facing adapter over Honua's GPServer-compatible task catalog:
an agent can discover Esri task aliases, read the GPServer-derived parameter
schema, submit a task, and follow its canonical job handle. It does not
federate or send credentials to an external ArcGIS Server.

Treat this roster as a fail-closed install check. A successful Terraform apply
with any profile missing from `tools/list` is not a complete AI handoff; verify
that the pinned Honua image is a 2026.1 candidate containing the admin catalog,
analysis profile, and Esri GP profile before giving the endpoint to an agent.
