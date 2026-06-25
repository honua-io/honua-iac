# examples/aws-cert — real-AWS certification tier

A Honua-owned stack that **certifies the serverless + GP-over-Batch path against
real AWS** (no LocalStack). It mirrors `examples/aws-demo` but is purpose-built
for certification: GP per-job Batch is **on**, federation is **GitHub OIDC**, and
a budget guardrail caps spend.

Tracks honua-iac#2164 (cert), honua-server umbrella #2166, GitOps→GP #2165.

## Architecture

- **Serverless everywhere, no standing compute.** The Honua server runs on
  Lambda + API Gateway; GP runs on **AWS Batch Fargate-Spot scale-to-zero**
  (`enable_gp_batch = true`) — nothing stays warm between jobs.
- **Per-job Batch.** The cert workflow re-applies `modules/aws-serverless` with
  a per-job `gp_batch_image` / `gp_batch_cpu_architecture` /
  `gp_batch_ephemeral_storage_gib` profile to mint a **job definition sized to
  the specific GP job**. vCPU / memory / GPU / timeout / retry are passed by the
  server's `AwsBatchComputeBackend` as **SubmitJob overrides** at submit time;
  only the three knobs SubmitJob cannot override (image, CPU architecture,
  ephemeral storage) are templated by terraform.
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
| `module.honua` (aws-serverless) | Lambda + API Gateway + RDS + GP Batch (Fargate-Spot, per-job) |
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

## Per-job apply (devops agent)

To certify a specific GP job, the honua-devops agent re-applies with that job's
profile:

```bash
terraform -chdir=infrastructure/terraform/examples/aws-cert apply \
  -var 'gp_batch_image=<acct>.dkr.ecr.us-east-1.amazonaws.com/honua-cert-cert-worker-gdal:job-1234' \
  -var 'gp_batch_cpu_architecture=ARM64'
```

The new job-definition revision's ARN is the `gp_batch_job_definition_arn`
output; the server submits against it with per-job vCPU/memory/timeout overrides.

## Notes

- **GP GPU is Fargate-incompatible.** `gp_batch_gpu_count > 0` only applies on an
  EC2 Batch compute environment; the cert path is Fargate-Spot, so GPU stays 0.
- **State:** uncomment the S3 backend in `versions.tf`
  (`cert/aws-cert/terraform.tfstate`) before the first real apply.
- **Budget email subscriptions** require each subscriber to confirm via the
  AWS-sent email before alerts deliver.
- Do not commit `terraform.tfvars`. Validated in CI; CI never runs `apply`.
