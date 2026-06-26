# examples/aws-cert — real-AWS certification tier

A Honua-owned stack that **certifies the serverless + GP-over-Batch path against
real AWS** (no LocalStack). It mirrors `examples/aws-demo` but is purpose-built
for certification: the durable GP Batch substrate is **on**, federation is
**GitHub OIDC**, and a budget guardrail caps spend.

Tracks honua-iac#2164 (cert), honua-server umbrella #2166, GitOps→GP #2165.

## Architecture

- **Serverless everywhere, no standing compute.** The Honua server runs on
  Lambda + API Gateway; GP runs on **AWS Batch Fargate-Spot scale-to-zero**
  (`enable_gp_batch = true`) — nothing stays warm between jobs.
- **Durable tiered substrate.** `modules/aws-serverless` mints a fixed **pool of
  job-definition size tiers** (`gp-s`/`gp-m`/`gp-l`/`gp-xl`) that differ only by
  ephemeral storage (the one knob SubmitJob cannot override). vCPU / memory /
  timeout / retry are applied by the server's `AwsBatchComputeBackend` as
  **SubmitJob overrides** at run time — there is **no per-job terraform apply**.
  The server selects a tier and submits against its job-definition ARN.
- **No long-lived keys.** The dispatched cert workflow assumes an IAM role via
  **GitHub OIDC** (`components/aws-github-oidc`), scoped by `sub` to the cert
  repo/environment and by permission to the `honua-cert-*` surface.
- **Cost guardrail.** An `aws_budgets_budget` with SNS email notifications caps
  monthly spend.

`name_prefix = "honua-cert"` + `environment = "cert"` ⇒ `honua-cert-cert-*`
ARNs, the surface the OIDC role is scoped to.

## What it creates

| Resource | Purpose |
|---|---|
| `module.honua` (aws-serverless) | Lambda + API Gateway + RDS + GP Batch substrate (Fargate-Spot, tiered job-def pool) |
| `aws_s3_bucket.cert_artifacts` | Private cert artifact bucket (GP I/O + evidence), versioned, lifecycled |
| `module.github_oidc` | GitHub OIDC provider + least-privilege cert role |
| `aws_budgets_budget.cert` + `aws_sns_topic.budget` | Monthly cost ceiling + alerts |
| worker-gdal ECR repo (via the module) | Dedicated GP worker image lifecycle |
| Custom-code Batch substrate (via the module, opt-in) | SEPARATE hardened Fargate-Spot queue + size-tier pool for **untrusted user code** |
| worker-customcode-python ECR repo (via the module, opt-in) | Dedicated custom-code worker image lifecycle |

## Usage

```bash
cp infrastructure/terraform/examples/aws-cert/terraform.tfvars.example \
   infrastructure/terraform/examples/aws-cert/terraform.tfvars
# fill in honua_image, honua_admin_password, budget_alert_emails, OIDC scoping
terraform -chdir=infrastructure/terraform/examples/aws-cert init
terraform -chdir=infrastructure/terraform/examples/aws-cert plan
# apply creates billable infra — run only intentionally for a cert session.
```

Wire the role into the cert workflow:

```yaml
permissions:
  id-token: write
  contents: read
steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: ${{ vars.HONUA_CERT_ROLE_ARN }}   # github_oidc_role_arn output
      aws-region: us-east-1
```

## Runtime contract (devops agent / server)

The cert apply is **once per environment**, not per job. The devops agent and the
server consume the substrate's exported ARNs as opaque runtime config and submit
jobs against them with per-job overrides — no terraform re-apply per job:

- `gp_job_queue_arn` — the Fargate-Spot job queue.
- `gp_job_definition_arns` — map `{ s, m, l, xl }` of the size-tier ARNs; the
  server picks the tier whose ephemeral storage fits the job, then applies
  vCPU / memory / timeout / retry as `SubmitJob` overrides.
- `gp_compute_environment_arn`, `gp_job_role_arn`, `gp_execution_role_arn`,
  `gp_worker_gdal_repository_url`.

## Custom-code (UNTRUSTED user code) substrate — locked down

`enable_customcode_batch` (off by default) provisions a **SEPARATE, deliberately
hardened** Batch family for running **untrusted user code** (the custom-code
Python runtime). It parallels the GP substrate's tiered Fargate-Spot scale-to-zero
shape (`customcode-s`/`m`/`l`/`xl`, differing only by ephemeral storage) but is
locked down. The deltas from the GP/GDAL family are the whole point:

- **Empty secrets.** The job definition injects **NO** Secrets Manager env refs —
  no DB connection string, no admin password, no master key. User code never sees
  platform secrets. It receives only the scoped runtime env the server injects at
  `SubmitJob` time (`HONUA_JOB_TOKEN`, `HONUA_API_ENDPOINT`,
  `customcode.output_prefix`, …).
- **Minimal task role.** A **distinct** task (job) role from the GP job role:
  **no** Secrets Manager, **no** RDS reach (no SG ingress to RDS, no 5432
  egress), **no** broad S3 — **only** `s3:GetObject`/`PutObject` scoped to the
  per-job artifact prefix (`customcode/*` under the artifact bucket). The job's
  callback to Honua is via the **scoped `HONUA_JOB_TOKEN`** (server-injected env),
  **not** AWS IAM — so the task role carries no platform-trust permissions.
- **Constrained egress.** The task security group is an **allowlist** (HTTPS +
  DNS to the operator-supplied CIDRs: PyPI/GitHub for pip+clone, the Honua API
  endpoint, the artifact S3), defaulting to the VPC CIDR only — **not** an open
  `0.0.0.0/0`. Full **two-phase egress isolation** (resolve deps with egress on,
  then run user code with egress off) is a **Beta hardening (Phase 3)**. For MVP
  the **scoped token is the primary T1/T2 trust boundary**; the egress allowlist
  is defense-in-depth.

Outputs (the cross-repo contract the server consumes, opaque ARNs):
`customcode_job_queue_arn`, `customcode_job_definition_arns` (`{ s, m, l, xl }`),
`customcode_task_role_arn`, `customcode_python_repository_url`. The server has no
custom-code-specific param keys on trunk yet, so these mirror the GP
`batch.job_queue_arn` / `batch.job_definition_arn` shape the
`AwsBatchComputeBackend` already reads.

## Notes

- **GP GPU is out of scope.** GPU needs an EC2 Batch compute environment; the
  cert path is Fargate-Spot. The module's `gp_gpu_enabled` flag is a placeholder
  that provisions nothing — leave it `false`.
- **State:** uncomment the S3 backend in `versions.tf`
  (`cert/aws-cert/terraform.tfstate`) before the first real apply.
- **Budget email subscriptions** require each subscriber to confirm via the
  AWS-sent email before alerts deliver.
- Do not commit `terraform.tfvars`. Validated in CI; CI never runs `apply`.
