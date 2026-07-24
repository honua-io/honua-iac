# examples/aws-cert — real-AWS certification tier

A Honua-owned stack that **certifies the serverless + GP-over-Batch path against
real AWS** (no LocalStack). It mirrors the `stacks/aws` root in the private
[honua-io/honua-demo](https://github.com/honua-io/honua-demo) repo (formerly
`examples/aws-demo` here — see honua-iac#126) but is purpose-built for
certification: the durable GP Batch substrate is **on**, federation is
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
  **GitHub OIDC** (`components/aws-github-oidc`), and by permission to the
  `honua-cert-*` surface. This stack pins the role's `sub` to the **tightest
  practical scope** — the `cert` GitHub Environment
  (`repo:honua-io/honua-server:environment:cert`), set as the default
  `github_oidc_subjects` — so the dispatched cert workflow **must run in a
  GitHub Environment named `cert`** or AWS will deny the assume-role.
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
| worker-customcode-python ECR repo (via the module, opt-in) | Dedicated python custom-code worker image lifecycle |
| worker-customcode-dotnet ECR repo (via the module, opt-in) | Dedicated .NET custom-code worker image lifecycle (honua-server #2196) |
| ECS/ALB weighted-cutover cell (`ecs-alb-cert.tf`, opt-in) | Internal ALB + weighted stable/canary target groups + one smallest-Fargate service attached to both — certifies the production `AwsEcsAlbDeployBackend` against real ELBv2/ECS APIs |

## Usage

```bash
cp infrastructure/terraform/examples/aws-cert/terraform.tfvars.example \
   infrastructure/terraform/examples/aws-cert/terraform.tfvars
# fill in honua_image, honua_admin_password, budget_alert_emails, OIDC scoping
terraform -chdir=infrastructure/terraform/examples/aws-cert init
terraform -chdir=infrastructure/terraform/examples/aws-cert plan
# apply creates billable infra — run only intentionally for a cert session.
```

Wire the role into the cert workflow. Because this stack pins the role's `sub`
to the `cert` GitHub Environment, the job **must declare `environment: cert`** —
the token `sub` only carries `environment:cert` when the job runs in that
Environment:

```yaml
permissions:
  id-token: write
  contents: read
jobs:
  certify:
    environment: cert   # REQUIRED — the OIDC role trusts only sub=...:environment:cert
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.HONUA_CERT_ROLE_ARN }}   # github_oidc_role_arn output
          aws-region: us-east-1
```

## Cross-repo variable mapping (terraform output → honua-server)

After `terraform apply`, wire the stack's outputs into the honua-server repo so
the dispatched cert workflow (honua-io/honua-server#2164) can reach this stack.
Each row is: **terraform output** → **honua-server Actions variable** (set under
the `cert` GitHub Environment) → **test env var** the workflow exports.

| terraform output | honua-server Actions variable | test env var |
|---|---|---|
| `github_oidc_role_arn` | `REALAWS_CERT_ROLE_ARN` | *(workflow `role-to-assume`)* |
| `gp_job_queue_arn` | `REALAWS_CERT_JOB_QUEUE_ARN` | `HONUA_REALAWS_CERT_JOB_QUEUE_ARN` |
| `gp_job_definition_arns.s` | `REALAWS_CERT_JOBDEF_ARN_S` | `HONUA_REALAWS_CERT_JOBDEF_ARN_S` |
| `gp_job_role_arn` | `REALAWS_CERT_JOB_ROLE_ARN` | `HONUA_REALAWS_CERT_JOB_ROLE_ARN` |
| `gp_execution_role_arn` | `REALAWS_CERT_EXECUTION_ROLE_ARN` | `HONUA_REALAWS_CERT_EXECUTION_ROLE_ARN` |
| `cert_artifact_bucket` | `REALAWS_CERT_ARTIFACT_BUCKET` | `HONUA_REALAWS_CERT_ARTIFACT_BUCKET` |

ECS/ALB weighted-cutover cell (only populated when `enable_ecs_alb_cert = true`;
the outputs are `null` otherwise):

| terraform output | honua-server Actions variable | test env var |
|---|---|---|
| `cert_ecs_cluster_name` | `REALAWS_CERT_ECS_CLUSTER` | `HONUA_REALAWS_CERT_ECS_CLUSTER` |
| `cert_ecs_service_name` | `REALAWS_CERT_ECS_SERVICE` | `HONUA_REALAWS_CERT_ECS_SERVICE` |
| `cert_alb_listener_arn` | `REALAWS_CERT_ALB_LISTENER_ARN` | `HONUA_REALAWS_CERT_ALB_LISTENER_ARN` |
| `cert_canary_target_group_arn` | `REALAWS_CERT_CANARY_TARGET_GROUP_ARN` | `HONUA_REALAWS_CERT_CANARY_TARGET_GROUP_ARN` |
| `cert_stable_target_group_arn` | `REALAWS_CERT_STABLE_TARGET_GROUP_ARN` | `HONUA_REALAWS_CERT_STABLE_TARGET_GROUP_ARN` |

The stack's default `region` is **`us-east-1`** (`variable "region"`); the
honua-server cert workflow aligns its `aws-region` to this value. Read the ARN
strings from `terraform output -raw <name>` (`gp_job_definition_arns` is a map —
`terraform output -json gp_job_definition_arns | jq -r .s` for the `s` tier).

### Per-run resource tagging

The cert stack's **standing** resources (the queue, the pooled job definitions,
the bucket, the role) carry `Purpose = real-aws-certification` (see
`local.tags`). The honua-server cert tests tag the **ephemeral** resources
**they** create per run — the registered job definitions and the S3 artifacts —
with `honua-cert-run=<id>` so a single run's resources can be identified,
verified, and torn down without disturbing the standing stack. The OIDC role
grants exactly the tag-write actions this needs on the honua-cert-* surface:
`batch:RegisterJobDefinition`/`DeregisterJobDefinition`/`TagResource`/`UntagResource`
on the job-definition prefix and `s3:PutObjectTagging`/`GetObjectTagging` on the
artifact bucket — no broader tagging or resource creation is permitted.

## Maintainer bootstrap checklist

One-time, per certification account:

1. **Dedicated account + region.** Use an isolated AWS account (blast-radius
   containment + clean budget attribution); keep `region = us-east-1` unless the
   honua-server workflow is realigned to match.
2. **Uncomment the S3 backend** in `versions.tf`
   (`cert/aws-cert/terraform.tfstate`) so state is durable before the first
   apply.
3. **Fill `terraform.tfvars`** from the example — `honua_image`,
   `honua_admin_password`, `db_password`, `budget_alert_emails`, and OIDC
   scoping (`github_oidc_subjects` defaults to the `cert` Environment sub).
4. **`terraform apply`** (creates billable infra — run intentionally).
5. **Create the GitHub Environment `cert`** in honua-io/honua-server (the OIDC
   role trusts only `sub=…:environment:cert`).
6. **Set the repo/Environment variables** from the mapping table above (via
   `gh variable set <NAME> --env cert --repo honua-io/honua-server`).
7. **Confirm the SNS budget subscription** — each `budget_alert_emails`
   recipient must click the AWS-sent confirmation before alerts deliver.

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
hardened** Batch substrate for running **untrusted user code** (the custom-code
**python** and **dotnet** runtimes — honua-server #2196). It parallels the GP
substrate's tiered Fargate-Spot scale-to-zero shape but is locked down. The
**runtime selector** (`customcode.runtime = python | dotnet`) the server sends
picks **only the image**: each runtime gets its own size-tier job-def family
(`customcode-python-{s,m,l,xl}`, `customcode-dotnet-{s,m,l,xl}`, tiers differing
only by ephemeral storage) sharing the **identical** task role, security group,
and queue — the security posture is **runtime-independent**. The deltas from the
GP/GDAL family are the whole point:

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
`customcode_job_queue_arn`, `customcode_job_definition_arns` (keyed
**`{runtime}.{tier}`** — `python.s`…`python.xl`, `dotnet.s`…`dotnet.xl`),
`customcode_task_role_arn`, `customcode_python_repository_url`,
`customcode_dotnet_repository_url`. The server resolves `customcode.runtime` + the
selected size tier to a single job-def ARN from the keyed map and submits against
it, mirroring the GP `batch.job_queue_arn` / `batch.job_definition_arn` shape the
`AwsBatchComputeBackend` already reads.

## ECS/ALB weighted-cutover certification cell (`enable_ecs_alb_cert`, opt-in)

Off by default. When `enable_ecs_alb_cert = true`, the stack provisions the
**minimal standing substrate** the server's production `AwsEcsAlbDeployBackend`
certifies against **real AWS ELBv2 + ECS APIs** (honua-server#2164). The backend
rewrites the ALB listener's weighted forward action between a **stable** and a
**canary** target group, calls `ecs UpdateService`, observes deployment
convergence, then rolls back by restoring the weights.

**What it creates (all `count`-gated on the toggle):**

- One **ECS cluster** (Fargate only — no standing EC2 capacity).
- One **ECS service** (`desired_count = 1`) running the **smallest Fargate task**
  (0.25 vCPU / 512 MB).
- Two **target groups** — `stable` (starts weight 100) and `canary` (starts
  weight 0).
- One **internal ALB** with a single **HTTP :80 listener** whose default rule is
  a **weighted forward** (stable 100 / canary 0).
- A CloudWatch log group, task-execution role, and two security groups (internal
  ALB ↔ task on :80; task egress 443 for image pull + DNS).

**Design — single service, dual target group.** One ECS service registers with
**both** target groups (two `load_balancer` blocks), so both always carry the
**same healthy tasks**. The weight-shift the backend performs is therefore a
**pure ALB-level cutover** — it certifies the **weight mechanics + service
convergence + rollback** without needing two service revisions. The
two-revision (blue/green with a distinct canary task set) variant is
**honua-server#2165** territory, not this cell.

**Internal ALB (`internal = true`).** The cert tests drive the AWS
**control-plane** APIs (ELBv2 `ModifyRule`/`ModifyListener`/`DescribeRules`, ECS
`UpdateService`/`DescribeServices`), **not** the HTTP data path, so the ALB
needs **no public exposure** — an internal scheme keeps the cell off the public
internet.

**Image — `public.ecr.aws/nginx/nginx:stable-alpine`.** A tiny, long-term-stable,
unauthenticated public image that serves HTTP 200 on `/` at port 80, so the
target-group health checks pass and the tasks converge to healthy with no Honua
build. It is pulled over the base cert stack's **existing NAT egress** from the
module's private subnets (`assign_public_ip = false`).

**VPC.** Reuses `module.honua`'s VPC and **private subnets** (the module's
`vpc_id` / `private_subnet_ids` / `vpc_cidr_block` outputs). No new VPC, NAT
gateway, or subnets are minted for the cell.

**Cost when on (default OFF).** Itemized standing cost while `enable_ecs_alb_cert
= true` (us-east-1, on top of the base cert stack):

- **1 internal Application Load Balancer** — ~**$16.20/mo** hourly
  ($0.0225/hr × ~720 hr) **plus** LCU charges (negligible for the cert cell's
  health-check-only traffic, typically well under $1/mo).
- **1 smallest Fargate task ~24/7** — 0.25 vCPU + 0.5 GB ≈ **$9/mo**
  (0.25 × $0.04048 + 0.5 × $0.004445, ×~730 hr).
- CloudWatch logs / ECR pulls — negligible.

≈ **$25–26/mo** standing while enabled. No new NAT gateway (reuses the base
stack's). **Turn the toggle off** (or run `terraform destroy` after a cert
session) to drop it to $0.

## Notes

- **Design note — fixed-tier pool, per-job overrides.** The GP substrate is a
  fixed pool of job-definition size tiers, not a per-job resource. Per-job
  **vCPUs / memory / timeout / retry ride `SubmitJob` overrides** at run time;
  **ephemeral storage picks the tier** (`gp-s`/`m`/`l`/`xl`) — the one knob
  `SubmitJob` cannot override. There is **no per-job terraform apply**, and this
  run-tagging change does not alter that fixed-tier-vs-per-job-pool design.
- **GP GPU is out of scope.** GPU needs an EC2 Batch compute environment; the
  cert path is Fargate-Spot. The module's `gp_gpu_enabled` flag is a placeholder
  that provisions nothing — leave it `false`.
- **State:** uncomment the S3 backend in `versions.tf`
  (`cert/aws-cert/terraform.tfstate`) before the first real apply.
- **Budget email subscriptions** require each subscriber to confirm via the
  AWS-sent email before alerts deliver.
- Do not commit `terraform.tfvars`. Validated in CI; CI never runs `apply`.
