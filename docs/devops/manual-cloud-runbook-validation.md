# Manual Cloud Runbook Validation + Evidence (AWS + Azure)

This is the operator procedure for executing the manual cloud runbooks
(**apply -> smoke -> destroy**) against real AWS and Azure accounts and
recording structured validation evidence for beta sign-off. It is the
repo-side companion to the upstream runbook docs and follows the same manual
runbook + evidence-capture conventions as the
[failover drill runbook](failover-drill-runbook.md) and
[`terraform-validation.md`](terraform-validation.md).

- Refs honua-io/honua-iac#20.
- Upstream runbook: `honua-io/honua-devops/docs/manual-cloud-runbooks.md`.
- Upstream smoke contract: `honua-io/honua-devops/scripts/smoke-contract.sh`.
- Upstream matrix: `honua-io/honua-devops/docs/deployment-validation-matrix.md`.
- Evidence schema: [`cloud-runbook-evidence-template.json`](cloud-runbook-evidence-template.json).
- Evidence helper:
  `scripts/capture-runbook-evidence.sh` (wrapper) ->
  `infrastructure/terraform/validation/scripts/shared/capture-runbook-evidence.sh`.

## What this issue delivers vs what needs live accounts

Executing the runbooks end-to-end **mutates real, billable cloud
infrastructure** and requires live AWS and Azure credentials plus published
image refs. Per `AGENTS.md`, `terraform apply` is never run against real
accounts without an explicit operator request. This document therefore splits
the deliverable cleanly:

| Part | Needs live cloud creds? | Status |
| --- | --- | --- |
| Runbook execution procedure (this doc) | no | delivered |
| Structured evidence schema + capture helper | no | delivered |
| Evidence grading logic (pass/fail verdicts) | no | delivered + self-tested |
| Static validate / fmt of touched roots | no | delivered (CI) |
| `apply -> smoke -> destroy` against AWS (AOT + JIT) | **yes** | operator action |
| `apply -> smoke -> destroy` against Azure (AOT + JIT) | **yes** | operator action |
| Populating the matrix with recorded run evidence | **yes** | operator action |

The remaining live executions are the explicit operator action recorded on
honua-io/honua-iac#20. Run them with the procedure below and attach the emitted
JSON evidence to the issue.

## Scope (matrix cells to execute)

At minimum, execute one AOT and one JIT path per cloud, per the upstream
[deployment validation matrix](https://github.com/honua-io/honua-devops/blob/main/docs/deployment-validation-matrix.md):

| Cloud | Target | Mode | Launch class | Local entrypoint |
| --- | --- | --- | --- | --- |
| AWS | `aws-serverless` (Lambda) | AOT | Must Pass | `run-aws-terraform-integration.sh --stack serverless --aot` |
| AWS | `aws-ecs` (ECS/Fargate) | JIT | Must Pass | `run-aws-terraform-integration.sh --stack ecs` |
| AWS | `aws-serverless` (Lambda) | JIT | Experimental | `run-aws-terraform-integration.sh --stack serverless` |
| AWS | `aws-ecs` (ECS/Fargate) | AOT | Experimental | `run-aws-terraform-integration.sh --stack ecs --aot` |
| Azure | `azure-functions` | AOT | Must Pass | `run-azure-terraform-integration.sh --stack functions --aot` |
| Azure | `azure-aca` (Container Apps) | JIT | Must Pass | `run-azure-terraform-integration.sh --stack aca` |
| Azure | `azure-functions` | JIT | Experimental | `run-azure-terraform-integration.sh --stack functions` |
| Azure | `azure-aca` (Container Apps) | AOT | Experimental | `run-azure-terraform-integration.sh --stack aca --aot` |

A single beta sign-off requires, at minimum, the four **Must Pass** cells plus
at least one AOT and one JIT cell per cloud (the Must Pass set already
satisfies the AOT/JIT-per-cloud requirement).

## Preconditions

1. Live cloud credentials are available (`aws sts get-caller-identity`,
   `az account show` both succeed). See
   [`terraform-validation.md`](terraform-validation.md) for the local creds
   setup and the required GitHub secrets.
2. Image refs are configured. The
   [#20 blocker](https://github.com/honua-io/honua-iac/issues/20) was missing
   image variables. Confirm they are populated before dispatching:
   - `HONUA_AWS_ECS_IMAGE`, `HONUA_AWS_SERVERLESS_IMAGE`
   - `HONUA_ACA_IMAGE`, `HONUA_FUNCTIONS_IMAGE`

   Seed them from the publish lane and verify:

   ```bash
   source <(scripts/tf-pass-secrets.sh export --scope publish)
   scripts/bootstrap-gh-vars.sh
   gh variable list --repo honua-io/honua-iac | grep -E 'HONUA_(AWS_ECS|AWS_SERVERLESS|ACA|FUNCTIONS)_IMAGE'
   ```

   See the Functions tag caveat in
   [`terraform-validation.md`](terraform-validation.md): use `*-functions-aot`
   (generic `latest`/`latest-aot` crash on Functions custom containers).
3. `jq`, `curl`, and Terraform `>= 1.5` are on `PATH`.

## Execution

Two equivalent paths. Prefer Option A (ephemeral GitHub workflow) for
auditable, auto-cleaned runs; use Option B for local debugging.

### Option A: dispatch the manual validation workflow (recommended)

```bash
gh workflow run terraform-manual-validation.yml \
  --repo honua-io/honua-iac \
  -f cloud=both \
  -f deployment_profile=ephemeral \
  -f run_live=true \
  -f no_destroy=false
```

`ephemeral` + `no_destroy=false` is the launch-safe posture: apply, smoke, and
auto-destroy in one run. Record the run URL for the evidence
`workflow_run_url` field.

### Option B: local apply -> smoke -> destroy

The live integration scripts run apply, an inline smoke pass, and destroy in
one invocation (compute is auto-destroyed by default). Example for the AWS
Lambda AOT cell:

```bash
source <(scripts/tf-pass-secrets.sh export)
time ./scripts/run-aws-terraform-integration.sh \
  --stack serverless \
  --aot \
  --serverless-image "<account>.dkr.ecr.<region>.amazonaws.com/honua-server:latest-lambda-aot-arm64"
```

If you need a standalone endpoint smoke against an already-applied stack, use
the upstream contract directly:

```bash
HONUA_SMOKE_BASE_URL="$(terraform -chdir=infrastructure/terraform/examples/aws-serverless output -raw honua_url)" \
HONUA_SMOKE_API_KEY="$HONUA_ADMIN_API_KEY" \
/path/to/honua-devops/scripts/smoke-contract.sh
```

The smoke contract checks the readiness, liveness, and (with an API key) admin
version endpoints. After the endpoint smoke passes, perform the
[admin UI verification](https://github.com/honua-io/honua-devops/blob/main/docs/manual-cloud-runbooks.md#admin-ui-verification)
pass; if the profile has no admin UI, record `admin-ui` as `not-present` and
rely on the authenticated admin-version probe as the minimum control-plane
proof.

## Pass / fail criteria

One matrix cell **passes** when all of the following hold:

- `terraform apply` succeeds (stack reaches healthy desired state).
- Smoke contract passes: readiness `2xx/3xx`, liveness `2xx/3xx`, and (when an
  API key is supplied) admin version `2xx/3xx`.
- Admin UI control-plane check passes, or is recorded `not-present` for
  profiles without an admin UI.
- `terraform destroy` succeeds.
- Post-destroy cleanup is verified (no application endpoint, load balancer,
  function app, or tagged validation resources remain).

A cell is **fail** if any required phase fails. A cell is **not-evaluated**
when the run is incomplete (a required phase was skipped/unrun).

## Evidence capture

Capture one JSON evidence object per matrix cell with the helper. It grades the
phases against the pass criteria, records per-check verdicts, sets the overall
`verdict`, and exits non-zero on `fail`:

```bash
scripts/capture-runbook-evidence.sh \
  --cloud aws \
  --target aws-serverless \
  --mode aot \
  --launch-class must-pass \
  --environment validation \
  --deployment-profile ephemeral \
  --operator "$(whoami)" \
  --image-ref "<account>.dkr.ecr.<region>.amazonaws.com/honua-server:latest-lambda-aot-arm64" \
  --honua-url "https://abc123.execute-api.us-west-2.amazonaws.com" \
  --workflow-run-url "https://github.com/honua-io/honua-iac/actions/runs/123456789" \
  --apply-result pass --apply-seconds 412 \
  --smoke-readiness pass --smoke-liveness pass --smoke-admin-version pass \
  --admin-ui not-present \
  --destroy-result pass --destroy-seconds 188 \
  --cleanup-verified true \
  --notes "Lambda AOT arm64; smoke via inline integration run" \
  --out evidence/aws-serverless-aot-$(date -u +%Y%m%d).json
```

Archive each JSON with the run and attach it to honua-io/honua-iac#20. Keep
real endpoints, account IDs, and credentials out of the repository — store
evidence as run artifacts or issue attachments, not committed files.

Running the helper with no phase flags emits a blank template matching
[`cloud-runbook-evidence-template.json`](cloud-runbook-evidence-template.json)
for manual editing.

## Beta sign-off checklist

Mark each cell when its evidence JSON is captured with `verdict: pass`:

- [ ] AWS Lambda AOT (Must Pass): apply/smoke/destroy pass, cleanup verified, evidence captured.
- [ ] AWS ECS JIT (Must Pass): apply/smoke/destroy pass, cleanup verified, evidence captured.
- [ ] Azure Functions AOT (Must Pass): apply/smoke/destroy pass, cleanup verified, evidence captured.
- [ ] Azure Container Apps JIT (Must Pass): apply/smoke/destroy pass, cleanup verified, evidence captured.
- [ ] At least one additional AOT and one JIT cell per cloud, or documented caveat.
- [ ] Admin UI verified (or `not-present`) for every executed cell.
- [ ] No retained resources, or each retained resource recorded with an owner and same-day cleanup plan.

## Common failure modes and gaps

| Symptom | Likely cause | Action |
| --- | --- | --- |
| Apply fails before provisioning | missing/empty image variable | populate `HONUA_*_IMAGE` (see Preconditions); the #20 blocker |
| Functions container exits `139` on boot | generic web tag on Functions custom container | use `*-functions-aot` tag, not `latest`/`latest-aot` |
| Smoke readiness times out after apply | cold image pull + migrations slower than probe budget | widen startup probe / `min_replicas`; retry smoke |
| Destroy leaves an ALB or log bucket | deletion protection / access logs on ephemeral stack | ECS validation forces these off; confirm `--no-destroy` was not set |
| Cleanup check still finds resources | partial destroy or out-of-band resources | re-run destroy; query tagged validation resources per cloud |
