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

## Notes

- **GP GPU is out of scope.** GPU needs an EC2 Batch compute environment; the
  cert path is Fargate-Spot. The module's `gp_gpu_enabled` flag is a placeholder
  that provisions nothing — leave it `false`.
- **State:** uncomment the S3 backend in `versions.tf`
  (`cert/aws-cert/terraform.tfstate`) before the first real apply.
- **Budget email subscriptions** require each subscriber to confirm via the
  AWS-sent email before alerts deliver.
- Do not commit `terraform.tfvars`. Validated in CI; CI never runs `apply`.
