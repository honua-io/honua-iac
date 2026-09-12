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
2. **Apply the state backend, then activate it.** Apply
   `bootstrap/aws-tfstate` on its own — with a `state_key_scopes` entry of
   `{ stack_name = "aws-cert", environment = "cert" }` — as a separate,
   explicitly decided operation. Then `cp backend.tf.example backend.tf` and
   replace every placeholder with that root's outputs, so state is remote,
   encrypted, versioned and locked before the first apply. Backend creation is
   never a side effect of `terraform init`, and `backend.tf` is gitignored
   because the filled-in copy names your account's bucket and role. Local state
   cannot certify anything: the governed wrappers refuse it with
   `REFUSED[local-state-refused]`. See [`docs/operator-state.md`](../../../../docs/operator-state.md).
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

## Operator contract (`honua.operator-contract/v1`)

`operator-contract.tf` renders the three structured outputs the honua-devops
agent consumes — `deployment_contract`, `validation_contract`,
`operations_contract` — plus the `operator_contract` envelope, its digest, and
its qualification status. Without them the agent can plan this root through the
exact-plan substrate but refuses to consume it
(`ProjectsOperatorContract = false`).

The projection describes **this** stack, not the ECS one. Four differences are
deliberate and are commented at their point of use:

- `stack.runtime` is `lambda`; the workload is a Lambda alias, so
  `workload.cluster_id` and the validation `cluster_arn` / `service_arn`
  selectors are `null` rather than invented.
- `rollout.current_revision` / `desired_revision` **are** projected. The ECS root
  nulls them because a task-set revision is observed after apply; a Lambda
  alias's function version is Terraform-owned state.
- `rollout.canary` is disabled. The ECS/ALB weighted-cutover cell is a
  certification fixture for the server's `AwsEcsAlbDeployBackend`, not a canary
  of this workload, so it is reported under the contract's `extensions` block
  alongside the GP / custom-code substrate ARNs and the artifact bucket.
- `dependencies.object_storage` is disabled: `modules/aws-serverless` exposes no
  Honua file-storage provider, and the cert artifact bucket is job scratch plus
  evidence storage, not the application's object-storage backend.

Two v1 fields have no honest serverless analogue and are recorded as
"none declared" rather than guessed: `workload.cluster_name` (required
non-empty; the stack's resource-group name stands in) and the
`desired_count` / `max_capacity` integers (a demand-driven alias with no
reserved concurrency declares no standing instance count).

Pass `operator_contract_identity` to qualify the contract. Omit it and the
contract is emitted with `status = "unqualified"`, which certified consumers
must reject. The scalar outputs above are **not** superseded by the contract —
they are the substrate runtime contract the honua-server cert fixture reads —
so unlike `examples/aws` they carry no deprecation marker.

```bash
terraform -chdir=infrastructure/terraform/examples/aws-cert output -json \
  | ./scripts/validate-operator-contract.sh --require-qualified -
```

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
- **State:** copy `backend.tf.example` to `backend.tf`
  (`honua/aws-cert/cert/terraform.tfstate`) after applying
  `bootstrap/aws-tfstate`, before the first real apply. Remote, encrypted,
  versioned and locked state is a precondition of certification, not a
  convenience.
- **Budget email subscriptions** require each subscriber to confirm via the
  AWS-sent email before alerts deliver.
- Do not commit `terraform.tfvars`. Validated in CI; CI never runs `apply`.

## Lambda GA certification substrate (release#282, ruling A)

`lambda-preview-cert.tf` adds the standing substrate for the server's
`lambda-preview-certification.yml` / `certify-lambda-preview.sh` lane. The
historical `preview` names are retained for compatibility; Lambda is a 2026.1
GA target. The inspected server revision is
`2ee4eb4eca080160cad4b2f4ba97cb0c370dc17d`.

**ECR login grant (coordinator ruling):** `aws ecr get-login-password` needs
`ecr:GetAuthorizationToken`, and [AWS exposes that action only on `Resource: "*"`](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ecr.html)
— it is registry-wide and has no repository ARN form. It is granted here as its
own statement, confined to the certification region by `aws:RequestedRegion`.
The wildcard is not a widening of repository access: the token only
authenticates the Docker client, and every repository operation stays bound to
the certification repository ARN by `MirrorAndVerifyCertificationImage`. The
policy gate permits exactly this one wildcard statement and fails on any other.
No trust policy is widened and no OIDC subject changes.

The image repository has the exact script-required name
`honua-cert-cert-lambda-preview`, immutable tags, scan on push, AES256 encryption,
and a lifecycle policy retaining the newest `lambda_preview_image_retention_count`
(default **10**, positive integer) images tagged `candidate-*`. The script derives
tags from the revision and digest and reuses existing immutable images. ECR
expires older candidates asynchronously; retain enough for active certification
runs. The runner cannot delete images or edit the repository policy.

The lane creates `honua-certrun-lambda-<run-id>-<attempt>` with the two tags
`honua-cert-run=<run-id>-<attempt>` and
`honua-purpose=lambda-preview-certification`, invokes `GET /healthz/live`, checks
CloudWatch evidence, and deletes its function and log group. The image remains
for reuse/evidence until lifecycle expiration. These ephemeral resources are
owned by the script and are not Terraform resources. The lane does **not** pass
`--vpc-config`; the execution role therefore has no VPC/ENI permissions.

### Pro license for the certification Lambda (operator ruling A, 2026-09-09)

Certification runs 28 and 29 failed the deployed-phase `addFeatures` assertion
with an in-body 402: the function ran Community and GeoServices editing is the
Pro entitlement `editing.featureserver-edits` (honua-server#4607 names the
cause in `serving-402:`; the assertion is deliberately not relaxed). The stack
now passes the module's license inputs through, **off by default**:

| Variable | Effect | Secret? |
|---|---|---|
| `enable_pro_license` | grants the Lambda role `secretsmanager:GetSecretValue` on the license secret; injects `Licensing__LicenseContentSecretRef` and `Licensing__TrustedKeys__<pro_license_key_id>` | No |
| `pro_license_secret_arn` | an EXISTING secret in this region holding the signed envelope (ruling A: a Secrets Manager replica of the demo stack's `honua-demo-demo/license-pro`); Terraform creates no secret and no version | No, an ARN |
| `pro_license_key_id` | hyphen-free keyId matching the envelope (`honuademo2026q2`); a mismatch silently serves Community | No |
| `pro_license_trusted_public_key` | the Ed25519 public key (`base64url:` prefix); verifies only, cannot mint | No |
| `pro_license_content` | escape hatch for Terraform to own the envelope; never commit a value | **Yes**, local secret tfvars only |

The envelope and the signing seed never live in this repository, in state
outputs, or in logs. Apply targeted (`module.honua` and its IAM policies, the
run-27 lesson: a new secret needs the module policies applied) and verify with
the alias `GET /api/v1/admin/license/status` (`edition=Pro`,
`validationState=Valid`) before dispatching the next certification run.

### Static plan summary — operator must confirm against governed state

This is a source-derived delta against the existing certification stack, **not
an executed AWS plan**. No AWS credentials, state, plan, or apply are used for
local validation. Expected delta: **7 creates, 0 changes, 0 destroys**, assuming
these addresses are absent and the existing stack has no unrelated drift:

| New Terraform resource | Purpose |
|---|---|
| `aws_ecr_repository.lambda_preview` | Immutable, scanned image repository |
| `aws_ecr_lifecycle_policy.lambda_preview` | Retain newest N candidate images |
| `aws_ecr_repository_policy.lambda_preview` | Lambda service image retrieval |
| `aws_iam_policy.lambda_preview_execution_boundary` | Bound execution to lane log streams |
| `aws_iam_role.lambda_preview_execution` | Lambda-service-only execution identity |
| `aws_iam_role_policy_attachment.lambda_preview_basic_execution` | Attach AWSLambdaBasicExecutionRole |
| `aws_iam_role_policy.lambda_preview_certification` | Add scoped permissions to existing certification OIDC role |

IAM notation below contains no account identifiers: `F` =
`arn:<partition>:lambda:<region>:<account>:function:honua-certrun-lambda-*`;
`L` = `arn:<partition>:logs:<region>:<account>:log-group:/aws/lambda/honua-certrun-lambda-*`;
`E` = the new repository ARN; `X` = the new execution-role ARN. Account, region,
and partition are Terraform-derived. All new statements are Allow unless marked
Deny. No OIDC subject or provider changes are introduced.

| Policy / statement | Actions | Resources | Conditions / principal |
|---|---|---|---|
| Execution trust / LambdaServiceOnly | `sts:AssumeRole` | Implicit attached role X (trust policy has no Resource field) | Only service `lambda.amazonaws.com`; no conditions |
| AWSLambdaBasicExecutionRole (AWS-managed) | `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` | `*` in AWS-managed policy | None; effective permissions intersect with the boundary below |
| Execution boundary / CertificationLogStreamsOnly | `logs:CreateLogStream`, `logs:PutLogEvents` | `L:log-stream:*` | None; runtime cannot create groups or access other AWS services |
| ECR policy / LambdaCertificationImagePull | `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` | E | Service `lambda.amazonaws.com`; StringEquals `aws:SourceAccount=<current account>`; ArnLike `aws:SourceArn=F` |
| OIDC / PreserveCertificationRun (Deny) | `lambda:TagResource` | F | Null `aws:ResourceTag/honua-cert-run=false` AND StringNotEquals request run tag to existing resource run tag |
| OIDC / PreserveCertificationPurpose (Deny) | `lambda:TagResource` | F | Null `aws:ResourceTag/honua-purpose=false` AND StringNotEquals request purpose tag to existing resource purpose tag |
| OIDC / CreateTaggedCertificationFunction | `lambda:CreateFunction`, `lambda:TagResource` | F | StringEquals request `honua-purpose=lambda-preview-certification`; StringLike request `honua-cert-run=?*-?*`; ForAllValues:StringEquals `aws:TagKeys=[honua-cert-run,honua-purpose]` |
| OIDC / ObserveCertificationFunction | `lambda:GetFunction`, `lambda:ListTags` | F | None (collision detection, waiters, ownership inspection, absence verification) |
| OIDC / InvokeAndDeleteTaggedCertificationFunction | `lambda:InvokeFunction`, `lambda:DeleteFunction`, `lambda:UpdateFunctionConfiguration` (cold-start nonce, honua-server#4548) | F | StringEquals resource `honua-purpose=lambda-preview-certification`; StringLike resource `honua-cert-run=?*-?*` |
| OIDC / PassOnlyCertificationExecutionRole | `iam:PassRole` | X | StringEquals `iam:PassedToService=lambda.amazonaws.com` |
| OIDC / EcrAuthorizationTokenGlobal | `ecr:GetAuthorizationToken` | `*` (AWS supports no resource-level form) | StringEquals `aws:RequestedRegion=<var.region>`; token authenticates only, repository access still bound to E below |
| OIDC / MirrorAndVerifyCertificationImage | `ecr:DescribeImages`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, `ecr:GetRepositoryPolicy`, `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage` | E | StringEquals resource `honua-purpose=lambda-preview-certification` |
| OIDC / CertificationLogGroupLifecycle | `logs:CreateLogGroup`, `logs:PutRetentionPolicy`, `logs:FilterLogEvents`, `logs:DeleteLogGroup` | `L:*` | None (the script creates untagged log groups) |

The [managed basic policy](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSLambdaBasicExecutionRole.html)
is explicitly requested by ruling A; its boundary permits only writes to the
precreated lane log streams. The [repository service policy](https://docs.aws.amazon.com/lambda/latest/dg/images-create.html#images-permissions)
is installed by Terraform, so the runner does not need `ecr:SetRepositoryPolicy`.
`logs:DescribeLogGroups` is already allowed by the existing component's
`CloudWatchReadGlobal`; no global read grant is added. The pre-existing policy
statements remain unchanged and are not part of the incremental IAM table.

IAM enforces namespace plus purpose/run tags, not exact session ownership: the
workflow uses a fixed OIDC role-session name without run-specific session tags.
The script checks the exact run tag before function deletion and checks log-name
ownership before deleting the untagged log group. Existing run/purpose tags
cannot be changed through the new tagging grant. The run-tag pattern requires
nonempty components around a hyphen; numeric validation belongs to GitHub's run
identifiers. A caller with this role can still operate on other correctly tagged
functions in this dedicated lane namespace.

### Operator handoff

Apply is **operator-run only**, after publishing a fingerprint-only plan summary
to the release evidence thread and reviewing the exact saved plan against the
existing governed backend. Confirm the seven additions above and **no destroys**;
stop on any unexpected changes, replacements, or trust differences. Do not create
a new empty state for this existing stack. No local validation command applies
infrastructure. Do not treat this packet as a passing GA receipt; it is the
substrate the lane needs, not a certification result.

After the reviewed operator apply, set these **repository variables**:

| Terraform output | Repository variable | Workflow/script environment |
|---|---|---|
| `REALAWS_CERT_LAMBDA_PREVIEW_EXECUTION_ROLE_ARN` | `REALAWS_CERT_LAMBDA_PREVIEW_EXECUTION_ROLE_ARN` | `HONUA_LAMBDA_PREVIEW_EXECUTION_ROLE_ARN` |
| `REALAWS_CERT_LAMBDA_PREVIEW_REPOSITORY` | `REALAWS_CERT_LAMBDA_PREVIEW_REPOSITORY` | `HONUA_LAMBDA_PREVIEW_REPOSITORY` |
| `github_oidc_role_arn` (existing) | `REALAWS_CERT_ROLE_ARN` (existing) | OIDC role-to-assume |

Both outputs are named for the repository variable they populate. The workflow
reads `vars.REALAWS_CERT_LAMBDA_PREVIEW_REPOSITORY` and
`vars.REALAWS_CERT_LAMBDA_PREVIEW_EXECUTION_ROLE_ARN`, then passes them to the
script as `HONUA_LAMBDA_PREVIEW_REPOSITORY` and
`HONUA_LAMBDA_PREVIEW_EXECUTION_ROLE_ARN`; do not create repository variables
under the script names. Check that `cert` Environment variables do not override
these repository values. Keep the existing `REALAWS_CERT_REGION` aligned with
the stack — the ECR authorization-token grant is conditioned on that region.

```bash
terraform -chdir=infrastructure/terraform/examples/aws-cert output -raw \
  REALAWS_CERT_LAMBDA_PREVIEW_EXECUTION_ROLE_ARN |
  gh variable set REALAWS_CERT_LAMBDA_PREVIEW_EXECUTION_ROLE_ARN --repo honua-io/honua-server
terraform -chdir=infrastructure/terraform/examples/aws-cert output -raw \
  REALAWS_CERT_LAMBDA_PREVIEW_REPOSITORY |
  gh variable set REALAWS_CERT_LAMBDA_PREVIEW_REPOSITORY --repo honua-io/honua-server
```

Run without shell tracing. Outputs are piped directly to GitHub; publish only
fingerprints in evidence, never raw account identifiers, ARNs/URIs, or state.
Local checks are `terraform fmt -check -recursive infrastructure/terraform`,
`terraform init -backend=false -input=false` followed by `terraform validate`
in this root, and the existing
`infrastructure/terraform/validation/scripts/shared/test-terraform-policy-gate.sh`.
The policy-gate tests include negative mutations for this substrate's IAM guards.

### Certification serving fixture — recorded, sha-pinned seed apply

The apply host needs Bash and `python3` (or `python`) with pip to build the PostGIS bootstrap package.

The lane's serving smoke asserts **all ten named rows and the exact count** on
`test_service/0` and writes its run-owned row to the scratch layer
`test_service/10` (`scripts/cloud/lambda-certification.md`). Nothing else in
this stack seeds a Honua serving fixture: `real-aws-certification.tf` covers the
control plane and `ecs-alb-cert.tf` runs nginx. So the cert database has to
carry honua-server's client-compat snapshot,
[`tests/seed/client-compat-v1.sql`](https://github.com/honua-io/honua-server/blob/trunk/tests/seed/client-compat-v1.sql)
— the same fixture `docker/client-compat/seed/run.sh` applies — before the lane
runs. **Missing or drifted fixture data fails the run.**

The cert RDS instance lives in private subnets, so the apply host cannot reach
it. The seed therefore goes in through the same in-VPC `postgis-bootstrap`
Lambda that enables PostGIS, in its `script` mode:

| Event key | Contract |
|---|---|
| `script_url` | https URL of the SQL file, pinned to an immutable commit. Fetched over the VPC's existing NAT egress; a redirect off https is refused. 8 MB ceiling. |
| `script_sha256` | Lowercase hex sha256 of those exact bytes. **Required** with `script_url`; a mismatch aborts before any database session is opened. |
| `script` | Inline SQL alternative (mutually exclusive with `script_url`), for ad-hoc maintenance. |

The Lambda splits the file with a dollar-quote / string / comment-aware splitter
— `client-compat-v1.sql` is 52 KB with two `$$` bodies whose plpgsql contains
`;` and `END;`, so `split(";")` would corrupt it — and runs every statement
inside **one transaction**. All-or-nothing: a half-applied fixture would fail the
lane's exact-count assertions in a way that looks like a server defect. A script
that manages transactions itself (`BEGIN`/`COMMIT`/`SAVEPOINT`/…) is refused
rather than half-applied, and an unterminated literal, identifier, dollar quote
or block comment is refused rather than truncated.

Seeding is **off by default** (both variables empty). To enable it:

```bash
# 1. Pick the honua-server revision whose fixture this cert database should
#    carry, and take the digest from the file at that exact commit.
SEED_REF=<40-hex honua-server commit sha>
git -C ../honua-server show "$SEED_REF:tests/seed/client-compat-v1.sql" | sha256sum
# Without a checkout, read the same bytes through the GitHub API:
gh api "repos/honua-io/honua-server/contents/tests/seed/client-compat-v1.sql?ref=$SEED_REF" \
  --jq .content | base64 -d | sha256sum
```

```hcl
# 2. terraform.tfvars — the URL names the bytes, the digest proves them.
cert_fixture_seed_url    = "https://raw.githubusercontent.com/honua-io/honua-server/<40-hex sha>/tests/seed/client-compat-v1.sql"
cert_fixture_seed_sha256 = "<64-hex sha256 from step 1>"
```

A `raw.githubusercontent.com` URL carrying a branch or tag instead of a commit
sha is rejected at plan time: the bytes behind it change without the Terraform
input changing, which is exactly the unrecorded apply this step replaces.

**To bump the fixture to a newer server revision**, change both variables
together. Terraform re-invokes the Lambda whenever the invocation input changes,
so the new seed is applied on the next apply. Every statement in
`client-compat-v1.sql` is idempotent (`CREATE ... IF NOT EXISTS`, `ON CONFLICT
DO UPDATE`), so re-applying converges the fixture — it does not reset unrelated
standing data. Changing only the digest fails the fetch verification; changing
only the URL fails the plan-time pin check.

What the apply records, so evidence can state which server revision's fixture
this cert database carries:

| Output | Contents |
|---|---|
| `cert_fixture_seed_applied` | `url`, verified `sha256`, `bytes`, `committed`, `statement_count`, `rows_affected` — `null` when seeding is disabled |
| `cert_fixture_seed_result` | The Lambda's full per-statement result (index, bounded statement echo, row count) |
| `cert_fixture_seed_source` | The pinned `url`, `sha256` and `seeding_enabled`, reported whether or not this apply invoked the seed — the record of which fixture revision this database carries |

`client-compat-v1.sql` at honua-server `ecc83d115` is 52,187 bytes and applies as
**69 statements**; publish the digest and statement count, never raw state.

**Turning seeding off does not unseed the database.** Destroying the invocation
performs no API call, so nothing undoes SQL already committed to RDS — and a
resource that has left the configuration keeps no state to read back, so the
pinned inputs are the only place a durable record can live. Turn seeding off
with the flag, not by emptying the URL:

```hcl
# Stop re-applying the fixture; keep the record of what the database carries.
cert_fixture_seed_enabled = false
cert_fixture_seed_url     = "https://raw.githubusercontent.com/honua-io/honua-server/<40-hex sha>/tests/seed/client-compat-v1.sql"
cert_fixture_seed_sha256  = "<64-hex sha256>"
```

`cert_fixture_seed_applied` and `cert_fixture_seed_result` describe *the apply
that ran*, so they necessarily read `null` once the invocation leaves state;
`cert_fixture_seed_source` still names the pinned revision, and `plan` warns
that the stack holds a fixture it is no longer applying. Emptying
`cert_fixture_seed_url` stops seeding just the same, but takes that record with
it — every output then reads `null` while the database still carries the last
fixture applied, which means *this stack is no longer naming a fixture
revision*, not *this database has no fixture*. Capture the evidence from the
apply that seeded it, and to stop carrying a fixture at all, destroy and
recreate the stack.

No new IAM, network or egress is granted: the seed rides the bootstrap Lambda's
existing Secrets Manager HTTPS egress rule and its existing role. The invocation
depends on `aws_lambda_invocation.postgis_bootstrap`, so PostGIS exists before
the snapshot's `GEOMETRY` columns are created, and the two share the function's
single reserved concurrent execution.

The splitter and the fetch/verify path have stdlib-only unit tests that need
neither the deployment zip nor a database:

```bash
python3 infrastructure/terraform/examples/aws-cert/postgis-bootstrap/test_handler.py
# Optionally split the real fixture too:
HONUA_CERT_SEED_SQL=../honua-server/tests/seed/client-compat-v1.sql \
  python3 infrastructure/terraform/examples/aws-cert/postgis-bootstrap/test_handler.py
```
