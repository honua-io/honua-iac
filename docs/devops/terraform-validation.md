# Terraform Validation Runbook

This runbook defines the on-demand Terraform validation flow for Honua across Azure, AWS, and Kubernetes.

## Scope

Validation is executed manually when Terraform changes are ready to verify. There is no nightly Terraform apply/destroy schedule in this flow.

## What gets validated

The workflow and scripts cover:

- Static validation: `terraform fmt`, `terraform init -backend=false`, `terraform validate`
- Policy/security gates: `tflint`, `checkov`, `tfsec`, and custom guard checks in `infrastructure/terraform/validation/scripts/shared/terraform-policy-gate.sh`
- Azure live integration: `examples/azure-data` bootstrap (Postgres + Redis) by default, then ACA + Functions using those existing connections; includes Redis wiring, PostGIS + raster checks, protocol/admin smoke checks, admin CRUD/query smoke (`create connection -> publish layer -> query`), idempotency, quick scale check, DB resilience drill, plan artifacts, compute auto-destroy, and reusable data-stack retention by default
- AWS live integration: `examples/aws-data` bootstrap (RDS + Redis) by default, then ECS + serverless using those existing connections/VPC; includes Redis wiring, PostGIS + raster checks, protocol/admin smoke checks, admin CRUD/query smoke (`create connection -> publish layer -> query`), idempotency, quick scale check, DB resilience drill, plan artifacts, and compute auto-destroy with reusable data-stack retention
- Kubernetes live integration: k3d + Helm + observability Terraform module, Helm static validation (`lint` + `template` + `kubeconform`), PostGIS + raster checks, protocol/admin smoke checks, admin CRUD/query smoke (`create connection -> publish layer -> query`), idempotency, quick scale check, and optional DB resilience drill
- Managed Kubernetes integration: AKS and EKS Terraform cluster provisioning, then Kubernetes validation flow, then auto-destroy + leak check
- Cross-repo platform validation: Azure, AWS, AKS, and EKS live jobs also check out `honua-server` and run its post-apply platform suite against the deployed environment before cleanup; this exercises deploy preflight, migration observability, admin OpenAPI, and optional cloud-staged import checks against real cloud infrastructure
- Drift detection: `terraform plan -detailed-exitcode` via `infrastructure/terraform/validation/scripts/shared/run-terraform-drift-detection.sh`

## Manual GitHub Actions workflow

Workflow: `.github/workflows/terraform-manual-validation.yml`

Dispatch inputs (10 total, within GitHub limit):

- `cloud`: `both|azure|aws`
- `deployment_profile`: `ephemeral|persistent`
- `apply_confirmation`: must be `APPROVED` when `deployment_profile=persistent`
- `run_live`: enable/disable live apply tests
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
- `HONUA_AWS_SERVERLESS_IMAGE` is derived from the `honua-server` ECR publish lane (`latest-lambda-aot`) when AWS credentials are available.
- `HONUA_ACA_IMAGE` and `HONUA_FUNCTIONS_IMAGE` prefer ACR when `ACR_LOGIN_SERVER` is configured in `honua-server`.
- `HONUA_K8S_IMAGE` continues to use the public GHCR `latest-aot` image by default.
- Validation stack vars are auto-synced to the image coverage that actually exists. For example, if only ACA is available on Azure, the helper sets `HONUA_AZURE_VALIDATION_STACK=aca` so the live workflow stops requiring Functions prematurely.

Recommended tag shapes:

- Azure Container Apps: generic image tag in ACR (`latest-aot` preferred, `latest` debug fallback); ACA runs `amd64`
- Azure Functions: ACR URI with `*-functions-aot` preferred; `*-functions` is the debug fallback; Functions custom containers are treated as `amd64`
- AKS: generic multi-arch image tag (`latest-aot` preferred, `latest` debug fallback); Arm node pools should pull the `arm64` variant automatically
- AWS ECS: ECR URI with `*-ecs-aot` preferred; `*-ecs` is the debug fallback; ECS validation defaults to `ARM64`
- AWS Lambda: ECR URI with `*-lambda-aot` preferred; `*-lambda` is the debug fallback; Lambda validation defaults to `arm64`

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
./infrastructure/terraform/validation/scripts/aws/run-aws-terraform-integration.sh --stack serverless --serverless-image "<account>.dkr.ecr.<region>.amazonaws.com/honua-server:latest-lambda-aot"
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
- Azure script behavior: when existing Azure data inputs are not provided, `infrastructure/terraform/validation/scripts/azure/run-azure-terraform-integration.sh` applies `infrastructure/terraform/examples/azure-data`, saves outputs to `/tmp/honua-azure-data-reuse.env` (or `HONUA_AZURE_DATA_CACHE_FILE`), reuses them in subsequent runs, and opens the PostgreSQL firewall to the ACA outbound IPs before readiness checks.
- Azure bootstrap validation now retries `az login` / `az account set` after creating the least-privilege service principal so Azure AD and subscription role assignment propagation does not fail fast on a fresh identity.
- Azure ACA validation defaults `min_replicas=1` and a wider startup probe budget so cold boot plus migrations can complete before ACA marks the revision unhealthy.
- AKS script defaults target `westus` with node VM size `Standard_D2s_v3` (override with `--location` / `--node-vm-size` if needed).
- AWS script behavior: when existing AWS data inputs are not provided, `infrastructure/terraform/validation/scripts/aws/run-aws-terraform-integration.sh` applies `infrastructure/terraform/examples/aws-data`. By default it now destroys that auto-created data stack on cleanup. Reuse is explicit: set `--keep-data` or `HONUA_AWS_KEEP_DATA=true` to save outputs to `/tmp/honua-aws-data-reuse.env` (or `HONUA_AWS_DATA_CACHE_FILE`) and reuse them in subsequent runs.
- AWS ECS validation forces `alb_deletion_protection=false` and `alb_access_logs_enabled=false` so ephemeral runs do not strand ALBs and log buckets during teardown.
- AWS ECS canary validation is opt-in. When `HONUA_AWS_ECS_CANARY_ENABLED=true`, the live script provisions the secondary ECS service with `0%` default traffic unless you explicitly set a non-zero `HONUA_AWS_ECS_CANARY_WEIGHT_PERCENTAGE`, waits for the canary tasks to become healthy, and verifies the ALB header route before continuing. Recommended rollout shape is still two-step: create canary at `0%`, verify, then raise weight in a later run.
- Azure Functions upgrade/rollback validation is now slot-based when `HONUA_RUN_UPGRADE_ROLLBACK=true`: the live script keeps production on the previous image, stages the candidate image in the configured deployment slot, exercises promote/rollback/restore through the Honua admin API, then reconciles Terraform back to the current image baseline.
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
