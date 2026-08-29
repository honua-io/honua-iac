# AWS Certification Live-Evidence Runbook (honua-iac#118)

The exact ordered commands to take a disposable AWS account from zero to the
live evidence honua-iac#118 requires, and back to zero.

Every command below is real — taken from the scripts, roots and modules on
`trunk`. Account-specific values appear as `<REPLACE_WITH_...>` placeholders and
are **never** invented: fill each one from the output of the step that produces
it.

> [!IMPORTANT]
> **This runbook has been written but not executed.** No step here has been run
> against a live AWS account. Writing it satisfies #118's "Publish an operator
> runbook" criterion; it satisfies none of the others. Executing it is the gate.

## What this runbook cannot claim

Read this section before quoting any part of the runbook as evidence.

1. **`examples/aws-cert` cannot satisfy most of #118's acceptance criteria.**
   #118 is written against the **ECS** topology: "the default single-task ECS
   path", "a valid MultiNode path with Redis", "prove both tasks become ready",
   "write a file through one task, replace/reschedule it, prove another task
   reads the same durable object", "scale-out/scale-in". The certification root
   is `modules/aws-serverless` — a Lambda behind an HTTP API Gateway, plus GP
   and custom-code AWS Batch substrates. **It has no Honua ECS service.** Its
   only ECS is the opt-in weighted-cutover cell, which runs a public `nginx`
   image as a fixture for the server's `AwsEcsAlbDeployBackend` — not Honua, and
   not a canary of anything.

   So the run is **two roots, not one**, and the table below says which
   criterion each can actually close. Do not report an `aws-cert` apply as
   evidence for an ECS criterion.

2. **`scripts/capture-runbook-evidence.sh` cannot record an `aws-cert` cell.**
   Its `--target` allowlist is `aws-ecs, aws-serverless, azure-aca,
   azure-functions`; passing `aws-cert` exits non-zero. Phase 5–7 evidence is
   therefore captured from the governed wrappers' own receipts, which is the
   stronger artifact anyway. Extending the allowlist is a separate change.

3. **Do not mix `run-aws-terraform-integration.sh` into this lane.** It requires
   long-lived `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, which is exactly
   the posture the governed wrappers refuse (`long-lived-credential-refused`).
   It is a different, older lane.

## Which root satisfies which #118 criterion

| #118 acceptance criterion | Root | Phase |
|---|---|---|
| Disposable environment from exact pinned revisions, secured remote state | both | 1–5 |
| Default single-task ECS path; readiness, telemetry, no accidental second task | `examples/aws` | 8 |
| MultiNode + Redis + pre-created S3; both tasks ready | `examples/aws` | 8 |
| Durable object survives task replacement | `examples/aws` | 8 |
| Scale-out/in, image update + rollback, health-gated | `examples/aws` | 8 |
| Task identity reaches only its bucket and secret; no secrets in plans/outputs | both | 9 |
| Restrictive bucket policy; KMS/CMK permissions documented | `examples/aws` | 9 |
| Evidence tied to commit, image digest, provider lock, account, region | both | 5–8 |
| Destroy without orphaning compute; external storage retained per ownership | both | 11 |
| Operator runbook published | — | this file |
| Operator-contract consumption by the honua-devops agent | `examples/aws-cert` | 7 |

## Dependencies on unlanded work

| Phase | Requires |
|---|---|
| 5, 7 | **honua-iac#163** — `examples/aws-cert/operator-contract.tf`. Without it the root emits no `deployment_contract`, and `terraform-exact-apply.sh --output-digest-name operator_contract_digest` has no output to read. |
| 6 (kms-mac only) | **honua-iac#164** (`enable_approval_mac_key`) **and honua-devops#178**. Until both land, approvals are `local-hmac-dev` and are **non-evidentiary** — usable to exercise the mechanism, not to certify it. |
| 7 | **honua-devops#176** (merged) for the consumption path. |

## Cost estimate

Rough `us-east-1` on-demand list prices at time of writing. **Not a quote** —
verify against the AWS pricing calculator before committing to a budget.

| Line item | Root | Rate | 24h | Notes |
|---|---|---|---|---|
| NAT Gateway | both | ~$0.045/h + $0.045/GB | ~$1.10 | **Usually the largest** idle cost |
| RDS `db.t4g.micro` single-AZ | aws-cert | ~$0.016/h + storage | ~$0.45 | cert pins micro, no Multi-AZ |
| RDS (aws default) | aws | instance-class dependent | — | MultiNode phase may add Multi-AZ |
| ALB | aws; aws-cert only if `enable_ecs_alb_cert` | ~$0.0225/h + LCU | ~$0.60 | cutover cell is **off by default** |
| Fargate task 0.25 vCPU / 512 MB | aws-cert cutover cell | ~$0.012/h | ~$0.30 | only while the cell is on |
| Fargate tasks | aws | ~$0.04/h per 0.5vCPU/1GB | ~$1–3 | scales with the MultiNode phase |
| ElastiCache Redis | aws MultiNode | node-class dependent | ~$0.30+ | `cache.t4g.micro` floor |
| KMS key (approval MAC) | #164 | $1/month | ~$0.03 | plus per-request |
| S3, CloudWatch Logs, API Gateway, Batch Fargate Spot | both | usage | <$0.20 | Batch is scale-to-zero |

A focused one-day run of both roots lands in the **low tens of dollars**. The
dominant risk is not the hourly rate — it is **leaving NAT Gateways and ALBs
running** after an aborted session. Phase 11 is not optional.

`examples/aws-cert` provisions an `aws_budgets_budget` with SNS alerts
(`monthly_budget_usd`, default 200). Set `budget_alert_emails` and **confirm the
subscription email** before Phase 5, or the alarm is silent.

## Preconditions

- Terraform **>= 1.10** (the S3 native lockfile). Below 1.10 you must bootstrap
  with `lock_mode = "dynamodb"` and swap the commented `dynamodb_table` line
  into `backend.tf`.
- `jq`, `aws` CLI, `node` (for the operator-contract validator).
- A **disposable** AWS account. Nothing here is safe against a shared account.
- An SSO session or federated principal that can create IAM roles, KMS keys, and
  S3 buckets for the three bootstrap roots. The bootstraps are applied with your
  operator identity; everything after Phase 4 runs as the *deployment role*.
- An immutable, digest-pinned Honua image already pushed to ECR.

```bash
cd <REPLACE_WITH_HONUA_IAC_CHECKOUT>
git rev-parse HEAD          # record: this is iac_revision in every receipt
mkdir -p out/evidence
```

---

## Phase 1 — state substrate

Backend creation is a separate, explicitly applied operation. `terraform init`
must never be the thing that creates the bucket.

The certification scope is **not** in the default `state_key_scopes` — it must
be passed. Without it the cert state key would be squatted rather than being a
first-class scope of the bucket.

```bash
terraform -chdir=infrastructure/terraform/bootstrap/aws-tfstate init

terraform -chdir=infrastructure/terraform/bootstrap/aws-tfstate apply \
  -var='bucket_name=<REPLACE_WITH_GLOBALLY_UNIQUE_BUCKET_NAME>' \
  -var='stack_name=aws' \
  -var='environment=prod' \
  -var='state_key_scopes=[{stack_name="aws-cert",environment="cert"}]'

terraform -chdir=infrastructure/terraform/bootstrap/aws-tfstate \
  output -json backend_contract > out/evidence/01-backend-contract.json
terraform -chdir=infrastructure/terraform/bootstrap/aws-tfstate \
  output -json state_keys        # confirm honua/aws-cert/cert/terraform.tfstate
```

Record: `state_bucket_name`, `state_bucket_arn`, `state_key`, `state_keys`,
`lock_mode`, `backend_access_policy_arn`, `backend_contract_digest`.

**Evidence:** `out/evidence/01-backend-contract.json`.

## Phase 2 — backend access role

This role reads and writes exactly one state object. It is never the deployment
role, and the least-privilege backend policy from Phase 1 must **not** be
attached to the deployment role.

```bash
terraform -chdir=infrastructure/terraform/bootstrap/aws-terraform-oidc init
terraform -chdir=infrastructure/terraform/bootstrap/aws-terraform-oidc apply \
  -var='oidc_provider_arn=<REPLACE_WITH_OIDC_PROVIDER_ARN>' \
  -var='oidc_provider_url=https://token.actions.githubusercontent.com' \
  -var='oidc_subject=<REPLACE_WITH_EXACT_OIDC_SUBJECT>' \
  -var='state_bucket_arn=<REPLACE_WITH_STATE_BUCKET_ARN>' \
  -var='state_object_arn=<REPLACE_WITH_STATE_OBJECT_ARN>' \
  -var='state_object_key=honua/aws-cert/cert/terraform.tfstate' \
  -var='state_lock_table_arn=<REPLACE_WITH_LOCK_TABLE_ARN_OR_EMPTY>'

terraform -chdir=infrastructure/terraform/bootstrap/aws-terraform-oidc \
  output -json workload_identity_contract > out/evidence/02-workload-identity.json
terraform -chdir=infrastructure/terraform/bootstrap/aws-terraform-oidc \
  output -raw workload_identity_contract_digest > out/evidence/02-workload-identity.digest
```

**Evidence:** `out/evidence/02-workload-identity.json` and its digest. The
digest is what Phase 5 passes as `--workload-identity-digest`.

## Phase 3 — execution identity (the four-role separation)

| Lane | Identity | Created by | May do |
|---|---|---|---|
| Backend access | `honua-terraform-backend` | Phase 2 + policy from Phase 1 | read/write one state object and its lock |
| Infra deployment | `<name_prefix>-<environment>-deploy` | **this phase** | provision the stack in one region |
| Task execution | `honua-*-execution` | `modules/aws-ecs` | pull images, fetch the task's secrets |
| App runtime | `honua-*-task` | `modules/aws-ecs` | what the application itself may call |

```bash
terraform -chdir=infrastructure/terraform/bootstrap/aws-exec-identity init
terraform -chdir=infrastructure/terraform/bootstrap/aws-exec-identity apply \
  -var='oidc_provider_arn=<REPLACE_WITH_OIDC_PROVIDER_ARN>' \
  -var='oidc_provider_url=https://token.actions.githubusercontent.com' \
  -var='oidc_subjects=["<REPLACE_WITH_EXACT_OIDC_SUBJECT>"]' \
  -var='state_bucket_arn=<REPLACE_WITH_STATE_BUCKET_ARN>' \
  -var='backend_access_role_arn=<REPLACE_WITH_BACKEND_ACCESS_ROLE_ARN>' \
  -var='backend_access_policy_arn=<REPLACE_WITH_BACKEND_ACCESS_POLICY_ARN>'

terraform -chdir=infrastructure/terraform/bootstrap/aws-exec-identity \
  output -json execution_identity_contract > out/evidence/03-execution-identity.json
terraform -chdir=infrastructure/terraform/bootstrap/aws-exec-identity \
  output -raw long_lived_credentials_created   # must print: false
```

**After honua-iac#164 lands**, add the approval MAC key in the same apply. The
signer is never defaulted — naming it is the whole separation:

```bash
  -var='enable_approval_mac_key=true' \
  -var='approval_signer_role_names=["<REPLACE_WITH_RELEASE_APPROVER_ROLE_NAME>"]'
  # approval_verifier_role_names defaults to this root's deployment role
```

```bash
terraform -chdir=infrastructure/terraform/bootstrap/aws-exec-identity \
  output -json approval_mac_contract > out/evidence/03-approval-mac.json
terraform -chdir=infrastructure/terraform/bootstrap/aws-exec-identity \
  output -raw approval_mac_key_arn      # feed to honua-devops in Phase 6
```

**Evidence:** `out/evidence/03-execution-identity.json`,
`out/evidence/03-approval-mac.json`, and the hard `false` marker.

## Phase 4 — activate the backend

```bash
cp infrastructure/terraform/examples/aws-cert/backend.tf.example \
   infrastructure/terraform/examples/aws-cert/backend.tf
```

Edit `backend.tf` and replace `REPLACE_WITH_STATE_BUCKET_NAME` with the Phase 1
bucket. Uncomment `assume_role` with the Phase 2 backend role — the backend
assumes the backend role while the provider assumes the deployment role, so
neither identity inherits the other's permissions. Leave the key as
`honua/aws-cert/cert/terraform.tfstate`.

`infrastructure/terraform/**/backend.tf` is gitignored; never commit it.

```bash
terraform -chdir=infrastructure/terraform/examples/aws-cert init

scripts/terraform-backend-identity.sh \
  --root infrastructure/terraform/examples/aws-cert \
  --output out/evidence/04-backend-identity.json
```

**Evidence:** `out/evidence/04-backend-identity.json` — account, region, bucket,
object key, locking primitive, encryption reference, and
`backend_config_digest`. No credentials, ever.

Repeat this phase for `examples/aws` with key `honua/aws/prod/terraform.tfstate`
before Phase 8.

## Phase 5 — governed plan of the certification root

Requires **honua-iac#163** for the operator-contract outputs.

```bash
cp infrastructure/terraform/examples/aws-cert/terraform.tfvars.example \
   infrastructure/terraform/examples/aws-cert/terraform.tfvars
# fill honua_image (digest-pinned), honua_admin_password (>=32 chars),
# budget_alert_emails, and the OIDC scoping. terraform.tfvars is never committed.

scripts/terraform-exact-plan.sh \
  --root infrastructure/terraform/examples/aws-cert \
  --action apply \
  --plan-out out/aws-cert.tfplan \
  --actor "operator:<REPLACE_WITH_OPERATOR_ID>" \
  --target-id "aws-cert:honua/cert" \
  --candidate-digest "<REPLACE_WITH_RELEASE_CANDIDATE_DIGEST>" \
  --workload-identity-digest "$(cat out/evidence/02-workload-identity.digest)" \
  --expires-in 3600
```

The script prints, and you must record, four lines:

```
[INFO] saved plan:      out/aws-cert.tfplan (sha256 <PLAN_SHA256>)
[INFO] plan metadata:   out/aws-cert.tfplan.metadata.json
[INFO] approval digest: <PLAN_METADATA_DIGEST>
[INFO] expires at:      <EXPIRES_AT>
```

```bash
export APPROVED_DIGEST="$(cat out/aws-cert.tfplan.metadata.json.digest)"
cp out/aws-cert.tfplan.metadata.json out/evidence/05-plan-metadata.json
```

The plan binds `state_before.lineage` and `state_before.serial`. Anything that
moves state between now and Phase 6 makes the apply refuse — that is the replay
barrier, not a nuisance.

**Evidence:** `out/evidence/05-plan-metadata.json`, the approval digest, the
plan SHA-256.

## Phase 6 — approval and governed apply

The approval is issued by honua-devops bound to `$APPROVED_DIGEST`. Configure
the verifier's signing mode first:

```bash
# After honua-iac#164 + honua-devops#178 — the evidentiary path:
export HONUA_DEVOPS_PROVISION_APPROVAL_SIGNING_MODE=kms-mac
export HONUA_DEVOPS_PROVISION_APPROVAL_ISSUER_KEY_ARNS="<REPLACE_WITH_ISSUER_ID>=<REPLACE_WITH_APPROVAL_MAC_KEY_ARN>"
```

> Until both land the mode is `local-hmac-dev`, whose receipts honua-devops
> stamps **NON-EVIDENTIARY** because the verifier holds the signing key. Use it
> to exercise the flow; do not cite it as approval evidence.

Apply exactly the approved plan, or refuse:

```bash
HONUA_IAC_REQUIRE_APPROVAL=1 scripts/terraform-exact-apply.sh \
  --plan out/aws-cert.tfplan \
  --approved-digest "$APPROVED_DIGEST" \
  --receipt-out out/evidence/06-exec-receipt.json
```

Prove the fail-closed path **before** the real apply, with a throwaway plan:

```bash
# no approval supplied -> refuses without mutating
HONUA_IAC_REQUIRE_APPROVAL=1 scripts/terraform-exact-apply.sh \
  --plan out/aws-cert.tfplan
# [ERROR] REFUSED[approval-binding-missing]: HONUA_IAC_REQUIRE_APPROVAL=1 but no --approved-digest was supplied

# every gate, no mutation
HONUA_IAC_REQUIRE_APPROVAL=1 scripts/terraform-exact-apply.sh \
  --plan out/aws-cert.tfplan --approved-digest "$APPROVED_DIGEST" --dry-run
```

**Evidence:** `out/evidence/06-exec-receipt.json` — the
`honua.terraform-exec-receipt/v1` document carrying `exit_status`,
`plan_metadata_digest`, `saved_plan_sha256`, `workload_identity`
(assumed role, account, credential kind), `backend_step`, `state_before` /
`state_after` lineage and serial, `output_contract` digest, and the teardown
handle. Capture the refusal transcripts too.

## Phase 7 — operator-contract consumption

Requires **honua-iac#163**. This is the step honua-iac#162 exists to unblock.

```bash
terraform -chdir=infrastructure/terraform/examples/aws-cert output -json \
  > out/evidence/07-terraform-output.json

./scripts/validate-operator-contract.sh --require-qualified \
  out/evidence/07-terraform-output.json
```

`--require-qualified` is the certified posture: an `unqualified` contract is
rejected with `E_UNQUALIFIED`. To be `qualified` the root needs
`operator_contract_identity` supplied with every pin — candidate digest,
manifest digest, IaC revision, terraform version, provider lock digest,
digest-pinned image reference and digest, backend config digest, state lineage
and serial, workload identity. Add it to `terraform.tfvars` in Phase 5 if you
intend to certify rather than smoke-test.

Then point the honua-devops agent at this root and confirm it resolves the root
as contract-projecting (`ProjectsOperatorContract = true`) and consumes the
three contracts rather than scraping `honua_url`.

**Evidence:** `out/evidence/07-terraform-output.json`, the validator transcript,
and the devops-side provision binding.

## Phase 8 — the ECS acceptance sequence

**This is `examples/aws`, not the certification root** — see "What this runbook
cannot claim". Repeat Phases 4–6 against
`infrastructure/terraform/examples/aws` with key `honua/aws/prod/terraform.tfstate`,
then run the sequence #118 demands. Each step is its own
plan → approve → apply cycle; a saved plan admits exactly one apply.

1. **Single-task baseline.** Apply the default single-task path. Probe
   `/healthz/ready` and `/healthz/live`; confirm telemetry export; confirm the
   service never runs a second task during an update.
2. **MultiNode + Redis + pre-created S3.** Re-plan with `deployment_mode`
   MultiNode, `redis_enabled = true`, and a bucket you created outside the
   module. Prove both tasks reach ready.
3. **Durable object across replacement.** Write an artifact through one task,
   force replacement (`aws ecs stop-task`, or a task-definition revision), and
   prove a different task reads the same object.
4. **Scale-out / scale-in.** Move `desired_count` up and back down. Capture the
   rollout at each step.
5. **Image update + rollback.** Apply a new digest-pinned image, health-gate it,
   then roll back to the previous digest. Prove no split local-file state.

Capture each phase with the evidence recorder (`aws-ecs` **is** in its
allowlist):

```bash
scripts/capture-runbook-evidence.sh \
  --cloud aws --target aws-ecs --mode aot \
  --operator "<REPLACE_WITH_OPERATOR>" --environment prod \
  --image-ref "<REPLACE_WITH_DIGEST_PINNED_IMAGE>" \
  --honua-url "<REPLACE_WITH_ENDPOINT>" \
  --apply-result pass --apply-seconds <N> \
  --smoke-readiness pass --smoke-liveness pass --smoke-admin-version pass \
  --out out/evidence/08-ecs-<step>.json
```

**Evidence:** one JSON per step plus each step's exec receipt.

## Phase 9 — IAM allow/deny proof points

Assume each role and prove both directions. A pass is only a pass if the paired
denial also holds.

| Principal | Must succeed | Must be denied |
|---|---|---|
| Deployment role | provision stack resources in its region | any S3/DynamoDB call against the state bucket and lock table |
| Deployment role | pass `honua-*-execution` / `honua-*-task` to `ecs-tasks.amazonaws.com` | `iam:PassRole` on itself or the backend role |
| Deployment role | — | `iam:CreateUser`, `iam:CreateAccessKey`, `iam:CreateLoginProfile` |
| Backend access role | read/write its one state object and lock | any other state key; any stack resource |
| App runtime role | read its configured bucket and secret | any other bucket or secret |
| Approval **issuer** (#164) | `kms:GenerateMac` on the approval key | `kms:VerifyMac` on it |
| Approval **verifier** (#164) | `kms:VerifyMac` on the approval key | `kms:GenerateMac` on it |

```bash
aws sts assume-role --role-arn <REPLACE_WITH_DEPLOYMENT_ROLE_ARN> \
  --role-session-name honua-cert-proof > out/evidence/09-deploy-session.json
# export the three session vars from that document, then:

aws s3api head-object --bucket <REPLACE_WITH_STATE_BUCKET_NAME> \
  --key honua/aws-cert/cert/terraform.tfstate    # expect AccessDenied
aws iam create-access-key --user-name any        # expect AccessDenied

# Approval MAC split (after #164). Two sessions, one action each:
aws kms generate-mac --key-id <REPLACE_WITH_APPROVAL_MAC_KEY_ARN> \
  --mac-algorithm HMAC_SHA_256 --message fileb://out/canonical-payload.bin
aws kms verify-mac  --key-id <REPLACE_WITH_APPROVAL_MAC_KEY_ARN> \
  --mac-algorithm HMAC_SHA_256 --message fileb://out/canonical-payload.bin \
  --mac fileb://out/mac.bin
```

Also confirm **no secret values** appear in the plan, the outputs, the receipts,
or CloudWatch logs. The operator contract carries references only; the validator
fails a leak with `E_SECRET_VALUE`.

**Evidence:** the `AccessDenied` transcripts. Redact account ids if the artifact
leaves the account boundary.

## Phase 10 — lock contention and replay refusal

Three distinct refusals, three transcripts.

**Concurrent apply.** Two executors, one saved plan:

```bash
HONUA_IAC_REQUIRE_APPROVAL=1 scripts/terraform-exact-apply.sh \
  --plan out/aws-cert.tfplan --approved-digest "$APPROVED_DIGEST" &
HONUA_IAC_REQUIRE_APPROVAL=1 scripts/terraform-exact-apply.sh \
  --plan out/aws-cert.tfplan --approved-digest "$APPROVED_DIGEST"
wait
```

The loser exits 3:

```
[ERROR] REFUSED[concurrent-claim]: another executor holds the claim for this saved plan (out/aws-cert.tfplan.claim); one plan admits one apply
```

**Replay of a spent plan.** Re-run after a completed apply:

```
[ERROR] REFUSED[plan-already-claimed]: this saved plan was already consumed at <TIMESTAMP>; regenerate and re-approve a new plan
```

**State drift.** Move state (e.g. a manual apply) between plan and apply:

```
[ERROR] REFUSED[state-serial-drift]: state serial mismatch: plan bound '<expected>' but the execution context reports '<actual>'
```

Recover from an ambiguous disconnect without replaying:

```bash
scripts/terraform-exact-apply.sh --plan out/aws-cert.tfplan --claim-status
# free | held | completed — a completed claim is never reclaimable
```

Terraform's own backend lock is bounded by `-lock-timeout=120s` on both plan and
apply.

**Evidence:** the three refusal transcripts and the `--claim-status` output.

## Phase 11 — teardown

Destroy is a governed operation too — plan it, approve it, apply it.

```bash
scripts/terraform-exact-plan.sh \
  --root infrastructure/terraform/examples/aws-cert \
  --action destroy \
  --plan-out out/aws-cert-destroy.tfplan \
  --actor "operator:<REPLACE_WITH_OPERATOR_ID>" \
  --target-id "aws-cert:honua/cert"

export DESTROY_DIGEST="$(cat out/aws-cert-destroy.tfplan.metadata.json.digest)"

HONUA_IAC_REQUIRE_APPROVAL=1 scripts/terraform-exact-apply.sh \
  --plan out/aws-cert-destroy.tfplan \
  --action destroy \
  --approved-digest "$DESTROY_DIGEST" \
  --receipt-out out/evidence/11-destroy-receipt.json
```

Repeat for `examples/aws`. Then **verify no orphans** — the cost risk lives here:

```bash
aws ec2 describe-nat-gateways --filter 'Name=state,Values=available'
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ecs list-clusters
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
aws batch describe-compute-environments --query 'computeEnvironments[].computeEnvironmentName'
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/honua-cert
```

Intentionally retained by documented ownership:

- the **state bucket** and its lock table (Phase 1) — they outlive the stack;
- the **approval MAC key** (Phase 3) — destroying it invalidates every receipt
  signed under it; scheduled deletion has a 7–30 day window;
- any **pre-created S3 storage** from Phase 8 step 2 — the modules deliberately
  do not own customer storage;
- the three bootstrap **IAM roles**.

Finally, tear down the bootstrap roots in reverse order only if the account is
being returned; otherwise leave them for the next session.

**Evidence:** `out/evidence/11-destroy-receipt.json` and the orphan-scan output.

## Evidence index

| File | Produced by | Schema |
|---|---|---|
| `01-backend-contract.json` | `bootstrap/aws-tfstate` output | — |
| `02-workload-identity.json` | `bootstrap/aws-terraform-oidc` output | — |
| `03-execution-identity.json` | `bootstrap/aws-exec-identity` output | — |
| `03-approval-mac.json` | `bootstrap/aws-exec-identity` output (#164) | — |
| `04-backend-identity.json` | `terraform-backend-identity.sh` | `terraform-backend-identity.v1` |
| `05-plan-metadata.json` | `terraform-exact-plan.sh` | `terraform-exact-plan.v1` |
| `06-exec-receipt.json` | `terraform-exact-apply.sh` | `terraform-exec-receipt.v1` |
| `07-terraform-output.json` | `terraform output -json` | `operator-contract.v1` |
| `08-ecs-*.json` | `capture-runbook-evidence.sh` | `cloud-runbook-evidence-template.json` |
| `09-*` | `aws sts` / `aws kms` transcripts | — |
| `10-*` | refusal transcripts | — |
| `11-destroy-receipt.json` | `terraform-exact-apply.sh` | `terraform-exec-receipt.v1` |

Every receipt already carries commit, provider-lock digest, account, and region.
Publish the set as immutable CI artifacts keyed by the Phase 0 commit.

## Pass / fail criteria

- Every governed apply consumed **the exact approved plan**; no plan was
  regenerated after approval.
- Every refusal above reproduced with **its named reason code**, not merely a
  non-zero exit.
- The operator contract validated `--require-qualified` against the applied
  cert root.
- Both directions of every Phase 9 IAM row held.
- No secret value appears in any artifact.
- Phase 11 orphan scan is empty except the documented retentions.

## Common failure modes and gaps

- **`REFUSED[local-state-refused]`** — `backend.tf` was not activated (Phase 4).
- **`REFUSED[lock-primitive-unsupported]`** — Terraform < 1.10 with
  `use_lockfile`. Re-bootstrap with `lock_mode = "dynamodb"`.
- **`REFUSED[source-changed]`** — the bound Terraform root moved between plan
  and apply. The apply re-derives the root from the plan metadata; it does not
  take `--root`.
- **Budget alarm silent** — the SNS email subscription was never confirmed.
- **`--var-file` not found** — paths resolve relative to `--root`, not the CWD.
- **`capture-runbook-evidence.sh` rejects `aws-cert`** — known gap, see above.
- **Cert GP job definitions** — the `*-lambda-aot` server image exits
  immediately under Batch; the tfvars example points `gp_batch_image` at
  `public.ecr.aws/docker/library/busybox:stable` for exactly this reason.
- **OIDC `sub` mismatch** — the cert stack pins the subject to the `cert` GitHub
  Environment; a workflow outside it is denied at
  `AssumeRoleWithWebIdentity`.
