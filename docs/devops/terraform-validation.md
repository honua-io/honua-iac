# Terraform Validation Runbook

This runbook defines the on-demand Terraform validation flow for Honua across Azure, AWS, and Kubernetes.

## Scope

Validation is executed manually when Terraform changes are ready to verify. There is no nightly Terraform apply/destroy schedule in this flow.

## Manual cloud runbook validation + evidence

The operator procedure for executing the apply -> smoke -> destroy runbooks
against live AWS/Azure accounts and recording structured beta-validation
evidence lives in
[`manual-cloud-runbook-validation.md`](manual-cloud-runbook-validation.md):

- Covers the AWS/Azure AOT and JIT matrix cells, pass/fail criteria, admin UI
  verification, and post-destroy cleanup checks.
- [`cloud-runbook-evidence-template.json`](cloud-runbook-evidence-template.json): canonical evidence schema per matrix cell.
- Evidence helper: `scripts/capture-runbook-evidence.sh` -> `infrastructure/terraform/validation/scripts/shared/capture-runbook-evidence.sh`.

## Disaster-recovery drill runbooks

Reliability drills for the validated managed targets live alongside this runbook:

- [`backup-restore-runbook.md`](backup-restore-runbook.md): AWS + Azure database backup/restore drills, post-restore smoke, pass/fail criteria, and failure modes.
- [`failover-drill-runbook.md`](failover-drill-runbook.md): AWS + Azure failover drills with RTO/RPO measurement.
- [`dr-evidence-template.json`](dr-evidence-template.json): canonical evidence schema for both drills.
- Evidence helper: `scripts/capture-dr-drill-evidence.sh` -> `infrastructure/terraform/validation/scripts/shared/capture-dr-drill-evidence.sh`.

The AWS and Azure live integration scripts already exercise an inline `verify_db_backup_restore` drill during validation; the runbooks above are the standalone operator procedures and the evidence contract used for reliability sign-off.

## What gets validated

The workflow and scripts cover:

- Static validation: `terraform fmt`, `terraform init -backend=false`, `terraform validate`
- Policy/security gates: `tflint`, `checkov`, and custom guard checks in `infrastructure/terraform/validation/scripts/shared/terraform-policy-gate.sh`. `tfsec` is an **optional, opt-in** scanner: it is disabled by default (it cannot parse this repository's Terraform `check` blocks) and is not installed or run in CI. Enable it locally with `HONUA_TERRAFORM_ENABLE_TFSEC=true` once a tfsec build that supports `check` blocks is available.
- Azure live integration: `examples/azure-data` bootstrap (Postgres + Redis) by default, then ACA + Functions using those existing connections; includes Redis wiring, PostGIS + raster checks, protocol/admin smoke checks, admin CRUD/query smoke (`create connection -> publish layer -> query`), idempotency, quick scale check, DB resilience drill, plan artifacts, compute auto-destroy, and reusable data-stack retention by default
- AWS live integration: `examples/aws-data` bootstrap (RDS + Redis) by default, then ECS + serverless using those existing connections/VPC; includes Redis wiring, PostGIS + raster checks, protocol/admin smoke checks, admin CRUD/query smoke (`create connection -> publish layer -> query`), idempotency, quick scale check, DB resilience drill, plan artifacts, and compute auto-destroy with reusable data-stack retention
- Kubernetes live integration: k3d + Helm + observability Terraform module, Helm static validation (`lint` + `template` + `kubeconform`), PostGIS + raster checks, protocol/admin smoke checks, admin CRUD/query smoke (`create connection -> publish layer -> query`), idempotency, quick scale check, and optional DB resilience drill
- Managed Kubernetes integration: AKS and EKS Terraform cluster provisioning, then Kubernetes validation flow, then auto-destroy + leak check
- Cross-repo platform validation: Azure, AWS, AKS, and EKS live jobs also check out `honua-server` and run its post-apply platform suite against the deployed environment before cleanup; this exercises deploy preflight, migration observability, admin OpenAPI, and optional cloud-staged import checks against real cloud infrastructure
- Seeded JS cloud demo smoke: a scheduled and manually dispatchable lane checks out `honua-sdk-js` and runs `npm run test:cloud-demo:config` plus credential-gated `npm run test:cloud-demo:staging` against the seeded demo tenant from `honua-sdk-js/examples/cloud-demo-services.json`
- Drift detection: `terraform plan -detailed-exitcode` via `infrastructure/terraform/validation/scripts/shared/run-terraform-drift-detection.sh`

## Manual GitHub Actions workflow

Workflow: `.github/workflows/terraform-manual-validation.yml`

Dispatch inputs (11 total, within GitHub's 25-input `workflow_dispatch` limit):

- `cloud`: `both|azure|aws`
- `deployment_profile`: `ephemeral|persistent`
- `apply_confirmation`: must be `APPROVED` when `deployment_profile=persistent`
- `run_live`: enable/disable live apply tests
- `reuse_data_stack`: reuse shared PostGIS/Redis data stacks across runs (default `true`)
- `run_k8s`: include local k3d Kubernetes validation
- `run_aks`: include AKS validation
- `run_eks`: include EKS validation
- `run_drift`: include drift detection job
- `no_destroy`: keep live resources after tests
- `allow_destroy_plan`: allow apply when plan contains destroys

Advanced controls (regions, stacks, SLO/cost caps, optional skips) are configured via repository variables instead of extra dispatch inputs.

## Required GitHub secrets

Common:

- `HONUA_ADMIN_PASSWORD`
- `HONUA_DB_PASSWORD`

Seeded cloud demo smoke:

- `HONUA_CLOUD_DEMO_API_KEY`
- `HONUA_CLOUD_DEMO_BEARER_TOKEN`
- `HONUA_CLOUD_DEMO_WRITE_TOKEN` (only when writable smoke is enabled)
- `HONUA_CLOUD_DEMO_RESET_TOKEN` (server-side smoke only; never expose as `VITE_*`)
- `HONUA_CLOUD_DEMO_RESET_URL` (server-side smoke only; use a secret when it embeds reset credentials)
- Optional browser read credentials: `VITE_HONUA_QUICKSTART_API_KEY`, `VITE_HONUA_QUICKSTART_BEARER_TOKEN`, `VITE_HONUA_SERVICE_EXPLORER_API_KEY`, `VITE_HONUA_SERVICE_EXPLORER_BEARER_TOKEN`, `VITE_HONUA_25D_API_KEY`, `HONUA_DEMO_API_KEY`, `HONUA_DEMO_BEARER_TOKEN`, `VITE_HONUA_EDIT_WORKFLOW_API_KEY`, and `VITE_HONUA_EDIT_WORKFLOW_BEARER_TOKEN`

Azure live / AKS:

- `ARM_CLIENT_ID`
- `ARM_CLIENT_SECRET`
- `ARM_TENANT_ID`
- `ARM_SUBSCRIPTION_ID`

AWS live / EKS:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN` (optional)

## Image configuration

Image refs are configuration, not secrets.

For GitHub Actions, set them as repository variables:

- Azure app images: `HONUA_ACA_IMAGE`, `HONUA_FUNCTIONS_IMAGE`
- Azure rollback images: `HONUA_ACA_PREVIOUS_IMAGE`, `HONUA_FUNCTIONS_PREVIOUS_IMAGE`
- AWS app images: `HONUA_AWS_ECS_IMAGE`, `HONUA_AWS_SERVERLESS_IMAGE`
- AWS rollback images: `HONUA_AWS_ECS_PREVIOUS_IMAGE`, `HONUA_AWS_SERVERLESS_PREVIOUS_IMAGE`
- AWS ECS canary image: `HONUA_AWS_ECS_CANARY_IMAGE`
- Kubernetes app images: `HONUA_K8S_IMAGE`, `HONUA_K8S_PREVIOUS_IMAGE`

The repo helper can seed the current validation variables for you:

```bash
source <(scripts/tf-pass-secrets.sh export --scope publish)
scripts/bootstrap-gh-vars.sh
```

Default behavior:

- `HONUA_AWS_ECS_IMAGE` is derived from the `honua-server` ECR publish lane (`latest-ecs-aot`) and is intentionally left unset when the ECR ECS lane is not reachable.
- `HONUA_AWS_SERVERLESS_IMAGE` is derived from the `honua-server` ECR publish lane (`latest-lambda-aot-arm64`) when AWS credentials are available.
- `HONUA_ACA_IMAGE` and `HONUA_FUNCTIONS_IMAGE` prefer ACR when `ACR_LOGIN_SERVER` is configured in `honua-server`.
- `HONUA_K8S_IMAGE` continues to use the public GHCR `latest-aot` image by default.
- Validation stack vars are auto-synced to the image coverage that actually exists. For example, if only ACA is available on Azure, the helper sets `HONUA_AZURE_VALIDATION_STACK=aca` so the live workflow stops requiring Functions prematurely.

Recommended tag shapes:

- Azure Container Apps: generic image tag in ACR (`latest-aot` preferred, `latest` debug fallback); ACA runs `amd64`
- Azure Functions: ACR URI with `*-functions-aot` preferred; `*-functions` is the debug fallback; Functions custom containers are treated as `amd64`
- AKS: generic multi-arch image tag (`latest-aot` preferred, `latest` debug fallback); Arm node pools should pull the `arm64` variant automatically
- AWS ECS: ECR URI with `*-ecs-aot` preferred; `*-ecs` is the debug fallback; ECS validation defaults to release-certified `X86_64` (`ARM64` is opt-in and must use an independently verified image)
- AWS Lambda: ECR URI with concrete `*-lambda-aot-arm64` preferred; `*-lambda-arm64` is the debug fallback; Lambda validation defaults to `arm64`

For local runs, prefer explicit script flags instead of exporting image refs as secrets:

- Azure: `--aca-image`, `--functions-image`, `--aca-previous-image`, `--functions-previous-image`
- AWS: `--ecs-image`, `--serverless-image`, `--ecs-previous-image`, `--serverless-previous-image`, `--ecs-canary-image`
- Kubernetes: set `HONUA_K8S_IMAGE` / `HONUA_K8S_PREVIOUS_IMAGE` in the shell only when you actually run the k8s path

## Local credentials setup (set-creds script)

For local runs, use the repo helper script instead of repeatedly exporting variables:

```bash
cp scripts/tf-secrets.local.example.sh scripts/tf-secrets.local.sh
chmod 600 scripts/tf-secrets.local.sh
# edit scripts/tf-secrets.local.sh with real values
source scripts/tf-secrets.local.sh
```

If you want local credentials to persist across branch switches without keeping a working file around, store only the real secrets in `pass` and load them on demand:

```bash
scripts/tf-pass-secrets.sh import --env-file scripts/tf-secrets.local.sh --force
source <(scripts/tf-pass-secrets.sh export)
```

To push the same pass-backed credentials into GitHub Actions secrets:

```bash
scripts/tf-pass-secrets.sh sync-gh --repo honua-io/honua-terraform
scripts/tf-pass-secrets.sh sync-gh --scope publish --repo honua-io/honua-server
```

`sync-gh --scope publish --repo honua-io/honua-server` now pushes only AWS and Azure cloud credentials. Registry identity is derived at runtime:

- ECR: from AWS credentials + `AWS_ECR_REGION`
- ACR: from Azure ARM credentials + repo variable `ACR_LOGIN_SERVER`

Then bootstrap the repo variables separately:

```bash
scripts/bootstrap-gh-vars.sh
```

Recommended default pass prefix is `honua/terraform/<ENV_VAR_NAME>`. Inspect the expected key mapping with:

```bash
scripts/tf-pass-secrets.sh paths
scripts/tf-pass-secrets.sh paths --scope publish
```

Quick auth checks before live runs:

```bash
aws sts get-caller-identity
az account show
```

## Recommended repository variables

- Region and stack selection:
  - `HONUA_AZURE_VALIDATION_REGION`, `HONUA_AWS_VALIDATION_REGION`
  - `HONUA_AZURE_VALIDATION_STACK` (`aca|functions|both`)
  - `HONUA_AWS_VALIDATION_STACK` (`ecs|serverless|both`)
- Image refs:
  - `HONUA_ACA_IMAGE`, `HONUA_FUNCTIONS_IMAGE`
  - `HONUA_ACA_PREVIOUS_IMAGE`, `HONUA_FUNCTIONS_PREVIOUS_IMAGE`
  - `HONUA_AWS_ECS_IMAGE`, `HONUA_AWS_SERVERLESS_IMAGE`
  - `HONUA_AWS_ECS_PREVIOUS_IMAGE`, `HONUA_AWS_SERVERLESS_PREVIOUS_IMAGE`
  - `HONUA_AWS_ECS_CANARY_IMAGE`
  - `HONUA_K8S_IMAGE`, `HONUA_K8S_PREVIOUS_IMAGE`
- Registry publish config:
  - `AWS_ECR_REGION`, `AWS_ECR_REPOSITORY`
  - `ACR_LOGIN_SERVER`, `ACR_REPOSITORY`
- Seeded cloud demo smoke:
  - `HONUA_CLOUD_DEMO_BASE_URL`
  - `HONUA_CLOUD_DEMO_METADATA_TTL_MS`
  - `HONUA_CLOUD_DEMO_ALLOW_WRITES` (`false` by default; set `true` only for disposable seeded services with reset credentials)
  - `VITE_HONUA_QUICKSTART_BASE_URL`, `VITE_HONUA_QUICKSTART_SERVICE_ID`, `VITE_HONUA_QUICKSTART_LAYER_ID`, `VITE_HONUA_QUICKSTART_WHERE`, `VITE_HONUA_QUICKSTART_RESULT_RECORD_COUNT`, `VITE_HONUA_QUICKSTART_BASEMAP_STYLE`
  - `VITE_HONUA_SERVICE_EXPLORER_BASE_URL`, `VITE_HONUA_SERVICE_EXPLORER_MODE`, `VITE_HONUA_SERVICE_EXPLORER_SERVICE_ID`, `VITE_HONUA_SERVICE_EXPLORER_LAYER_ID`, `VITE_HONUA_SERVICE_EXPLORER_WHERE`, `VITE_HONUA_SERVICE_EXPLORER_RESULT_RECORD_COUNT`, `VITE_HONUA_SERVICE_EXPLORER_MAP_MOVE_DEBOUNCE_MS`, `VITE_HONUA_SERVICE_EXPLORER_SOURCE_ID`
  - `VITE_HONUA_25D_BASE_URL`, `VITE_HONUA_25D_ASSETS_COLLECTION`, `VITE_HONUA_25D_ROUTE_COLLECTION`, `VITE_HONUA_25D_STOPS_COLLECTION`, `VITE_HONUA_25D_BASEMAP_STYLE`
  - `HONUA_DEMO_BASE_URL`, `HONUA_DEMO_ENV_LABEL`, `HONUA_DEMO_INCIDENTS_SERVICE_ID`, `HONUA_DEMO_INCIDENTS_LAYER_ID`, `HONUA_DEMO_UNIT_TRACKS_SERVICE_ID`, `HONUA_DEMO_UNIT_TRACKS_LAYER_ID`, `HONUA_DEMO_COVERAGE_ZONES_SERVICE_ID`, `HONUA_DEMO_COVERAGE_ZONES_LAYER_ID`
  - `VITE_HONUA_INCIDENT_TRANSPORT`, `VITE_HONUA_INCIDENT_STREAM_URL`
  - `VITE_HONUA_EDIT_WORKFLOW_BASE_URL`, `VITE_HONUA_EDIT_WORKFLOW_SERVICE_ID`, `VITE_HONUA_EDIT_WORKFLOW_LAYER_ID`, `VITE_HONUA_EDIT_WORKFLOW_READONLY_SERVICE_ID`
- Cost/SLO:
  - `HONUA_MAX_RUN_COST_USD`
  - `HONUA_READY_SLO_SECONDS`
  - `HONUA_MAX_LOAD_ERROR_RATE_PERCENT`
  - `HONUA_TTL_HOURS`
- Optional behavior toggles:
  - `HONUA_USE_AOT` (`true|false`; switches default images to `latest-aot` in validation scripts)
  - `HONUA_AZURE_FUNCTIONS_AOT_AUTOSWITCH` (`true|false`; defaults to `true` for AOT-first Functions image selection)
  - `HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_ENABLED` (`true|false`; provisions a staging slot so the control-plane handoff includes slot rollout metadata)
  - `HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_NAME` (defaults to `staging`)
  - `HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_IMAGE` (optional explicit staging-slot image; defaults to the primary Functions image)
  - `HONUA_RUN_UPGRADE_ROLLBACK`
  - `HONUA_SKIP_DB_RESILIENCE`
  - `HONUA_SKIP_QUOTA_PREFLIGHT`
  - `HONUA_SKIP_HELM_STATIC_VALIDATION`
  - `HONUA_SKIP_OBSERVABILITY`
  - `HONUA_SKIP_IDEMPOTENCY`
  - `HONUA_SKIP_PROTOCOL_CHECKS`
  - `HONUA_SKIP_SCALE_CHECK`
- Optional existing dependency reuse (faster/cheaper validation runs):
  - `HONUA_AZURE_EXISTING_DB_FQDN`
  - `HONUA_AZURE_EXISTING_DB_CONNECTION_STRING`
  - `HONUA_AZURE_EXISTING_REDIS_CONNECTION_STRING`
  - `HONUA_AZURE_DATA_CACHE_FILE` (defaults to `/tmp/honua-azure-data-reuse.env`)
  - `HONUA_AZURE_DESTROY_DATA` (`true|false`, default `false`)
  - `HONUA_AZURE_LOGIN_MAX_ATTEMPTS` / `HONUA_AZURE_LOGIN_RETRY_SECONDS` (bootstrap SP propagation retry budget)
  - `HONUA_AWS_EXISTING_DB_ENDPOINT`
  - `HONUA_AWS_EXISTING_DB_CONNECTION_STRING`
  - `HONUA_AWS_EXISTING_REDIS_CONNECTION_STRING`
  - `HONUA_AWS_ECS_CANARY_ENABLED`
  - `HONUA_AWS_ECS_CANARY_DESIRED_COUNT`
  - `HONUA_AWS_ECS_CANARY_WEIGHT_PERCENTAGE`
  - `HONUA_AWS_ECS_CANARY_HEADER_NAME`
  - `HONUA_AWS_ECS_CANARY_HEADER_VALUE`
  - `HONUA_AWS_EXISTING_VPC_ID`
  - `HONUA_AWS_EXISTING_VPC_CIDR`
  - `HONUA_AWS_EXISTING_PUBLIC_SUBNET_IDS`
  - `HONUA_AWS_EXISTING_PRIVATE_SUBNET_IDS`
  - `HONUA_AWS_KEEP_DATA` (`true|false`, default `false`; opt-in local/CI data reuse)
  - `HONUA_AWS_DATA_CACHE_FILE` (defaults to `/tmp/honua-aws-data-reuse.env`)
  - `HONUA_AWS_DESTROY_DATA` (`true|false`, default `true`)
- Drift:
  - `HONUA_DRIFT_ROOTS`
  - `HONUA_DRIFT_VAR_FILES`

## Manual run examples

CLI:

```bash
gh workflow run terraform-manual-validation.yml \
  -f cloud=both \
  -f deployment_profile=ephemeral \
  -f apply_confirmation= \
  -f run_live=true \
  -f run_k8s=true \
  -f run_aks=true \
  -f run_eks=true \
  -f run_drift=true \
  -f reuse_data_stack=true \
  -f no_destroy=false \
  -f allow_destroy_plan=false
```

Separate AWS and Azure dispatches on the same ref:

```bash
./scripts/dispatch-terraform-manual-validation.sh --cloud both --ref trunk
```

Single combined run (legacy behavior):

```bash
./scripts/dispatch-terraform-manual-validation.sh --cloud both --single-run --ref trunk
```

Local script entry points:

```bash
# Default flow provisions/reuses examples/azure-data, then runs compute stack validation.
./infrastructure/terraform/validation/scripts/azure/run-azure-terraform-integration.sh --stack both
./infrastructure/terraform/validation/scripts/azure/run-azure-terraform-integration.sh --stack both --force-new-data-infra
./infrastructure/terraform/validation/scripts/azure/run-azure-terraform-integration.sh --stack both --destroy-data
./infrastructure/terraform/validation/scripts/azure/run-azure-terraform-integration.sh --stack both --aot
./infrastructure/terraform/validation/scripts/azure/run-azure-terraform-integration.sh \
  --stack aca \
  --existing-db-fqdn mypg.postgres.database.azure.com \
  --existing-db-connection "Host=mypg.postgres.database.azure.com;Port=5432;Database=honua;Username=honua;Password=***;SSL Mode=Require;Trust Server Certificate=false" \
  --existing-redis-connection "myredis.redis.cache.windows.net:6380,password=***,ssl=True,abortConnect=False"
./scripts/run-azure-terraform-integration.sh --stack both
./infrastructure/terraform/validation/scripts/aws/run-aws-terraform-integration.sh --stack both
./infrastructure/terraform/validation/scripts/aws/run-aws-terraform-integration.sh --stack data --no-destroy
./infrastructure/terraform/validation/scripts/aws/run-aws-terraform-integration.sh --stack both --keep-data
./infrastructure/terraform/validation/scripts/aws/run-aws-terraform-integration.sh --stack ecs --aot
./infrastructure/terraform/validation/scripts/aws/run-aws-terraform-integration.sh \
  --stack ecs \
  --ecs-canary-enabled \
  --ecs-canary-image "<account>.dkr.ecr.<region>.amazonaws.com/honua-server:canary-aot" \
  --ecs-canary-weight 0
./infrastructure/terraform/validation/scripts/aws/run-aws-terraform-integration.sh --stack serverless --serverless-image "<account>.dkr.ecr.<region>.amazonaws.com/honua-server:latest-lambda-aot-arm64"
./scripts/run-aws-terraform-integration.sh --stack serverless
./infrastructure/terraform/validation/scripts/aws/run-aws-terraform-integration.sh \
  --stack ecs \
  --existing-db-endpoint mydb.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com \
  --existing-db-connection "Host=mydb.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com;Port=5432;Database=honua;Username=honua;Password=***;SSL Mode=Require;Trust Server Certificate=false" \
  --existing-redis-connection "mycache.xxxxxx.use1.cache.amazonaws.com:6379,password=***,ssl=true"
./infrastructure/terraform/validation/scripts/k8s/run-k8s-terraform-integration.sh
./infrastructure/terraform/validation/scripts/k8s/run-k8s-terraform-integration.sh --aot
./infrastructure/terraform/validation/scripts/azure/run-aks-terraform-integration.sh
./infrastructure/terraform/validation/scripts/aws/run-eks-terraform-integration.sh
./scripts/run-aks-terraform-integration.sh
./scripts/run-eks-terraform-integration.sh
./scripts/run-k8s-terraform-integration.sh
./infrastructure/terraform/validation/scripts/shared/terraform-policy-gate.sh
./infrastructure/terraform/validation/scripts/shared/run-terraform-drift-detection.sh --root infrastructure/terraform/examples/azure
```

## Seeded JS cloud demo smoke

Workflow: `.github/workflows/cloud-demo-smoke.yml`

This workflow validates the seeded Honua Cloud demo service contract owned by
`honua-sdk-js#128`. It checks out this repo for validation helpers, checks out
`honua-sdk-js`, writes an environment summary from
`examples/cloud-demo-services.json`, and runs:

```bash
npm run test:cloud-demo:config
npm run test:cloud-demo:staging
```

It runs daily at 11:17 UTC and can be triggered manually:

```bash
gh workflow run cloud-demo-smoke.yml \
  --repo honua-io/honua-terraform \
  -f sdk_ref=trunk \
  -f strict_env=true
```

Secret setup:

```bash
source <(scripts/tf-pass-secrets.sh export --scope cloud-demo 2>/dev/null)
scripts/tf-pass-secrets.sh sync-gh --scope cloud-demo --repo honua-io/honua-terraform
```

`HONUA_CLOUD_DEMO_ALLOW_WRITES` is a repository variable and defaults to
`false`. Set it to `true` only when `HONUA_CLOUD_DEMO_WRITE_TOKEN`,
`HONUA_CLOUD_DEMO_RESET_TOKEN`, and `HONUA_CLOUD_DEMO_RESET_URL` are present
and the target service is disposable seeded data. The summary script fails if
any reset or write safeguard is exposed through a populated `VITE_*` variable.

The workflow uploads two artifacts when available:

- `cloud-demo-env-summary.json`: repo-variable/secret presence, required
  profile env status, and write/reset safeguard checks
- `cloud-demo-smoke.json`: the JS SDK staging smoke summary

The scheduled run is strict by default. Missing seeded profile env or
credentials should fail the workflow so demo readiness is visible instead of
falling back silently to fixtures.

## Notes

- Azure/AWS credential secrets are treated as bootstrap credentials. The workflow creates ephemeral least-privilege identities per stack (`aca`, `functions`, `ecs`, `serverless`, `aks`, `eks`), runs validation with those identities, then destroys them.
- Dedicated bootstrap modules used by the workflow:
  - `infrastructure/terraform/bootstrap/azure-aca`
  - `infrastructure/terraform/bootstrap/azure-functions`
  - `infrastructure/terraform/bootstrap/azure-aks`
  - `infrastructure/terraform/bootstrap/aws-ecs`
  - `infrastructure/terraform/bootstrap/aws-serverless`
  - `infrastructure/terraform/bootstrap/aws-eks`
- Use one database admin secret: `HONUA_DB_PASSWORD` (not separate per cloud).
- AWS bootstrap principals are per-run IAM users (`honua-tf-{ecs,sls,eks}-<run-id>-<attempt>`) with active access keys, tagged `Owner=terraform-validation` / `ValidationRunId` / `ExpiresAtUTC`. The AWS/EKS live jobs run an `if: always()` cleanup step that re-drives the bootstrap destroy and purges the run's users by name (keys deactivated and deleted first), so cancellation, timeout, or a crash before state was written can no longer strand credentials-bearing users (#129).
- Backstop janitor: `.github/workflows/terraform-validation-iam-sweeper.yml` runs `infrastructure/terraform/validation/scripts/aws/sweep-orphaned-validation-iam.sh` daily. It enumerates read-only first, prints the deletion plan, then deletes expired `honua-tf-*` users, `Owner=terraform-validation` roles/policies whose `ExpiresAtUTC` has elapsed, and orphaned Container Insights log groups from `*-it-cluster` validation clusters (the in-run leak janitor cannot see IAM because the Resource Groups Tagging API does not index it). Dispatch with `dry_run=true` to inspect without deleting; the age threshold for untagged historical users defaults to 24 hours.
- Every AWS/EKS live job reaps its own cell on **every** exit path (#142). An `if: always()` step runs `infrastructure/terraform/validation/scripts/aws/sweep-orphaned-validation-infra.sh --this-run --run-id gha-<run-id>-aws-{ecs,serverless}` (and `-eks`), which deletes the run's own tagged infrastructure straight through the AWS API and appends what survived to the job summary. It exists because the in-script `trap cleanup EXIT` cannot run when the runner is cancelled or lost, and because a `terraform destroy` that errors is only warned about. When `reuse_data_stack=true` the run-scoped reap is restricted to `--stack ecs --stack serverless`, so the deliberately retained data stack is left to the scheduled reaper once its TTL elapses.
- Backstop infra reaper: `.github/workflows/terraform-validation-infra-reaper.yml` runs the same script daily without `--this-run`. It is the only thing that catches a cell whose runner died before any step ran, and the shared data stack that `--keep-data` retained for a reuse that never came — two of the 28 leaking runs in #142 concluded `success`, so teardown-on-failure alone would not have caught them. Dispatch it with `dry_run=true` (the dispatch default) to see the plan; the schedule supplies no inputs and therefore performs a real sweep.
- What stops the reaper deleting something live, in order: `Owner=terraform-validation` is the only thing that makes a resource a candidate at all (an untagged resource is unreachable by construction); the resource must carry a `ValidationRunId` of the form `gha-<run id>-*`; that GitHub run must be `completed` (queued/in-progress/unconfirmable is refused); the run must be outside `--grace-hours` (default 4); the resource's own `ExpiresAtUTC` TTL must have elapsed; `--protect-run-id` ids are untouchable; `--max-delete` (default 400) abandons an implausibly large plan rather than executing it; and the whole sweep defers while **any** `terraform-manual-validation` run is in progress, because a retained data stack is tagged with the run that created it rather than the one currently reusing it. `--dry-run` issues no mutating API call at all. `infrastructure/terraform/validation/scripts/aws/test-sweep-orphaned-validation-infra.sh` (wired into `terraform-ci.yml`) asserts each of those refusals against a fake `aws`/`gh` on PATH, plus the teardown ordering below.
- Out of scope by design: resources whose `ValidationRunId` is not of the form `gha-<run id>-*` — the ids local runs of `run-aws-terraform-integration.sh` generate (`aws-<timestamp>`) — are never reaped automatically, because nothing proves the run behind them is over. A dry run reports them under `SKIP ... does not name a GitHub run`; clean those up by hand.
- Teardown ordering the reaper enforces, both learned from real stalls: security groups that reference each other's rules cannot be deleted in any order, so every rule on every non-default SG in the VPC is revoked before any group is deleted; and detached-but-alive ENIs hold their subnet and their security group, so they are swept before subnets are touched (the same failure honua-release#79 hit with the EKS VPC CNI's secondary ENIs, whose harness sweep this mirrors).
- Validation resources now also carry a `Stack` tag (`data` | `ecs` | `serverless` | `eks`) so a run-scoped teardown can reap the throwaway compute stacks without destroying a data stack it was told to keep.
- Azure script behavior: when existing Azure data inputs are not provided, `infrastructure/terraform/validation/scripts/azure/run-azure-terraform-integration.sh` applies `infrastructure/terraform/examples/azure-data`, saves outputs to `/tmp/honua-azure-data-reuse.env` (or `HONUA_AZURE_DATA_CACHE_FILE`), reuses them in subsequent runs, and opens the PostgreSQL firewall to the ACA outbound IPs before readiness checks.
- Azure bootstrap validation now retries `az login` / `az account set` after creating the least-privilege service principal so Azure AD and subscription role assignment propagation does not fail fast on a fresh identity.
- Azure ACA validation defaults `min_replicas=1` and a wider startup probe budget so cold boot plus migrations can complete before ACA marks the revision unhealthy.
- Azure Functions validation now uses a temporary PostgreSQL firewall rule for Azure services on Premium/Consumption-style plans (`EP*`, `Y1`) because App Service outbound IP metadata is not stable enough to use as the only DB allowlist during validation. Cleanup removes that rule after the run.
- AKS script defaults target `westus` with node VM size `Standard_D2s_v3` (override with `--location` / `--node-vm-size` if needed).
- AWS script behavior: when existing AWS data inputs are not provided, `infrastructure/terraform/validation/scripts/aws/run-aws-terraform-integration.sh` applies `infrastructure/terraform/examples/aws-data`. By default it now destroys that auto-created data stack on cleanup. Reuse is explicit: set `--keep-data` or `HONUA_AWS_KEEP_DATA=true` to save outputs to `/tmp/honua-aws-data-reuse.env` (or `HONUA_AWS_DATA_CACHE_FILE`) and reuse them in subsequent runs.
- AWS ECS validation forces `alb_deletion_protection=false` and `alb_access_logs_enabled=false` so ephemeral runs do not strand ALBs and log buckets during teardown.
- AWS ECS canary validation is opt-in. When `HONUA_AWS_ECS_CANARY_ENABLED=true`, the live script provisions the secondary ECS service with `0%` default traffic unless you explicitly set a non-zero `HONUA_AWS_ECS_CANARY_WEIGHT_PERCENTAGE`, waits for the canary tasks to become healthy, and verifies the ALB header route before continuing. Recommended rollout shape is still two-step: create canary at `0%`, verify, then raise weight in a later run.
- Azure Functions upgrade/rollback validation is now slot-based when `HONUA_RUN_UPGRADE_ROLLBACK=true`: the live script keeps production on the previous image, stages the candidate image in the configured deployment slot, exercises promote/rollback/restore through the Honua admin API, then reconciles Terraform back to the current image baseline.
- Azure Functions cloud post-apply validation only exercises a configured deploy target when slot outputs are present. Non-slot runs do not advertise a rollout target and now skip the live deploy-plan cloud test entirely, because that endpoint is not yet a reliable gating contract on non-slot Functions deployments.
- Current known issue (February 28, 2026): generic web tags (`latest`, `latest-aot`) crash on Azure Functions custom container startup (container exit code `139`). Use Functions-targeted tags (`*-functions-aot` preferred, `*-functions` debug fallback).
- Registry strategy: web runtime tags (`latest`, `latest-aot`, versioned base tags) are published to GHCR/Docker Hub, while cloud-targeted platform tags (`*-ecs`, `*-ecs-aot`, `*-lambda`, `*-lambda-aot`, `*-functions`, `*-functions-aot`) are published by CI directly to cloud registries (ECR/ACR).
- `.terraform` directories are already ignored in `.gitignore`.
- Live scripts auto-destroy compute resources by default unless `--no-destroy` / `no_destroy=true` is set. Azure still retains the data stack by default for reuse and only tears it down when `--destroy-data` (or `HONUA_AZURE_DESTROY_DATA=true`) is set. AWS now does the opposite: it destroys auto-created data by default, and only keeps/reuses it when `--keep-data` / `HONUA_AWS_KEEP_DATA=true` is set. GitHub manual validation still passes `--destroy-data` automatically for `deployment_profile=ephemeral` when `no_destroy=false`.
- GitHub-hosted runners do not preserve `/tmp` between runs. In CI, true data-stack reuse can come from either repository vars or secrets. Use vars for nonsecret topology like `HONUA_AZURE_EXISTING_DB_FQDN`, `HONUA_AWS_EXISTING_DB_ENDPOINT`, and `HONUA_AWS_EXISTING_VPC_*`. Use secrets for connection strings such as `HONUA_AZURE_EXISTING_DB_CONNECTION_STRING`, `HONUA_AZURE_EXISTING_REDIS_CONNECTION_STRING`, `HONUA_AWS_EXISTING_DB_CONNECTION_STRING`, and `HONUA_AWS_EXISTING_REDIS_CONNECTION_STRING`.
- The manual validation workflow now has `reuse_data_stack=true` by default. For GitHub-hosted runs it restores/saves the Azure and AWS data-cache files with GitHub Actions cache, so the first successful reusable run creates the shared PostGIS/Redis stack and subsequent runs on the same ref/region can skip rebuilding it.
- Azure ephemeral CI reuse works by omitting `--destroy-data` and restoring `${GITHUB_WORKSPACE}/.gha-cache/azure-data-reuse.env`. AWS ephemeral CI reuse works by passing `--keep-data` and restoring `${GITHUB_WORKSPACE}/.gha-cache/aws-data-reuse.env`.
- Azure reuse is now resilient to compute-stage failures: if the Azure data stack was created successfully and `destroy-data` is disabled, the workflow keeps that PostGIS/Redis stack for the next run even when ACA/Functions verification fails later.
- The manual validation workflow concurrency key now includes `inputs.cloud`, so separate `cloud=aws` and `cloud=azure` dispatches can run concurrently on the same ref without blocking each other.
- To run the cross-repo platform suite locally after apply, point the live validation scripts at the `honua-server` runner: `export HONUA_PLATFORM_VALIDATION_SCRIPT=/path/to/honua-server/scripts/run-cloud-post-apply-validation.sh`.
