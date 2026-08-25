# Terraform exact-plan execution contract

This is the non-secret backend / init / plan / apply metadata contract that
honua-devops consumes to bind a human approval to exactly one Terraform
mutation, and to verify — before any process starts — that nothing about the
execution context moved between approval and execution.

honua-iac owns the execution substrate described here. It does **not** issue,
store, or interpret approvals; honua-devops owns the durable provisioning
operation, the approval receipt, and the process invocation.

Nothing in this contract is a secret. Variable values are hashed, Terraform
state is reduced to `lineage` + `serial` before it leaves the pipe, backend
configuration keys that could carry a credential are listed by name and never by
value, and no token, source credential, or session name is ever recorded.

## The three documents

| Document | Produced by | Schema |
|---|---|---|
| Backend identity | `scripts/terraform-backend-identity.sh` | `contracts/terraform-backend-identity.v1.schema.json` |
| Exact-plan metadata | `scripts/terraform-exact-plan.sh` | `contracts/terraform-exact-plan.v1.schema.json` |
| Execution receipt | `scripts/terraform-exact-apply.sh` | `contracts/terraform-exec-receipt.v1.schema.json` |

Schemas live under `infrastructure/terraform/contracts/` and ship in the
customer distribution tarball.

## Canonical form and digests

Every digest in this contract is the SHA-256 of a **canonical JSON**
serialization: keys sorted, no insignificant whitespace, ASCII-escaped
(`json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=True)`).

`plan_metadata_digest` is the SHA-256 of the plan metadata document **with the
`plan_metadata_digest` field removed**. A consumer verifies it by deleting that
key, re-serializing canonically, and re-hashing. This is the value an approval
binds to.

## What the plan binds

`scripts/terraform-exact-plan.sh` records, before it hands anything to a human:

| Bound fact | Field |
|---|---|
| Terraform root | `source.terraform_root` |
| IaC revision and module sources | `source.iac_revision`, `source.iac_tree_digest`, `source.module_sources` |
| Terraform version | `toolchain.terraform_version` |
| Provider lock digest | `toolchain.provider_lock_digest` |
| Backend config digest | `backend.backend_config_digest` |
| Target account and partition | `identity.account_id`, `identity.partition` |
| Region, workspace, object key | `backend.region`, `backend.workspace`, `backend.object_key` |
| Inputs | `inputs.input_digest` (values hashed; `inputs.input_refs` names sources only) |
| Prior state lineage/serial | `state_before.lineage`, `state_before.serial` |
| Action | `action` (`apply` or `destroy`) |
| Expiry | `expires_at_utc` |
| Saved plan SHA-256 | `plan.sha256` |

`posture.release_qualified` is the single boolean the release lane reads. It is
true only when the backend is remote, a locking primitive is configured, the
source is committed, local state was not opted into, and the caller is a live
STS-assumed-role session. Any development escape hatch turns it false, and
`terraform-exact-apply.sh` refuses a false plan unless the operator passes
`--allow-unqualified` explicitly.

`qualification_status` is always `"unqualified"` and `evidence_scope` is always
`"metadata-only-pre-apply"`: a plan is never, by itself, evidence that anything
was applied.

## Fail-closed matrix

`scripts/terraform-exact-apply.sh` re-derives every bound fact from the live
context and refuses **before any mutation**. Each refusal prints
`REFUSED[<reason>]` and exits 3.

| Reason code | Refuses when |
|---|---|
| `saved-plan-missing` / `plan-metadata-missing` | the artifact pair is incomplete |
| `metadata-tampered` | the metadata no longer hashes to its own recorded digest |
| `approval-digest-mismatch` | the approval was issued for a different plan |
| `approval-binding-missing` | `HONUA_IAC_REQUIRE_APPROVAL=1` and no approval was supplied |
| `action-mismatch` | an apply plan is run as a destroy, or the reverse |
| `plan-expired` | the plan outlived `expires_at_utc` |
| `saved-plan-tampered` | the `.tfplan` bytes no longer match `plan.sha256` |
| `unqualified-plan-refused` | the plan was produced under a development escape hatch |
| `concurrent-claim` | another executor holds the claim for this plan |
| `plan-already-claimed` | the plan was already consumed (replay) |
| `terraform-version-changed` | the Terraform binary moved |
| `provider-lock-changed` | `.terraform.lock.hcl` moved |
| `source-changed` | the revision or the source tree digest moved |
| `mutable-source` | the source is uncommitted or unpinnable |
| `provider-lock-missing` | the root has no provider lock at all |
| `backend-substituted` | the resolved backend config digest moved |
| `local-state-refused` | the backend is local state |
| `lock-posture-missing` | the remote backend names no locking primitive |
| `lock-primitive-unsupported` | S3 native locking on Terraform < 1.10 |
| `workspace-mismatch` | the workspace moved |
| `account-mismatch` / `role-mismatch` | a different account or execution role |
| `long-lived-credential-refused` | the caller is a long-lived IAM user |
| `input-digest-changed` | any input value or var file changed |
| `state-lineage-changed` / `state-serial-drift` | state was substituted or moved on |

Every row above is covered by
`infrastructure/terraform/validation/scripts/shared/test-terraform-exact-plan.sh`,
which runs fully offline against a fake `terraform` and fixtures.

## One plan, one lock holder, one apply

The apply wrapper takes a one-time claim with an atomic `mkdir` beside the saved
plan. A second concurrent executor loses the race deterministically
(`concurrent-claim`); a completed claim makes a later replay
`plan-already-claimed`. A refusal removes the claim so the operator can fix the
cause and retry the same approved plan.

After an ambiguous client disconnect, `--claim-status` reports whether the claim
is `free`, `held`, or `completed` without touching anything. `--reclaim-after
<seconds>` takes over a claim that was acquired but never completed. A
**completed** claim is never reclaimable — recovery must not become replay.

## What the receipt records

On completion the wrapper writes an evidence-safe receipt joining `exit_status`,
`state_after.lineage`/`serial`, the output contract digest
(`operator_contract_digest` from the stack, read by name so sensitive outputs
are never enumerated), the workload identity reference, the backend step, and
the cleanup/teardown handle. No secrets, no state contents.

## Offline / test mode

The two operations that need live AWS — `sts get-caller-identity` and
`terraform state pull` — read fixtures when `HONUA_IAC_OFFLINE=1`, so the whole
fail-closed matrix is testable without credentials. Offline runs are stamped
`identity.evidence_mode = "offline-test"` and can never present as
release-qualified evidence.

## Worked sequence

```bash
# 0. once per account: bootstrap/aws-tfstate, bootstrap/aws-terraform-oidc,
#    bootstrap/aws-exec-identity (see infrastructure/terraform/README.md)

# 1. what backend am I about to touch?
scripts/terraform-backend-identity.sh \
  --root infrastructure/terraform/examples/aws \
  --output backend-identity.json

# 2. produce the exact plan and its approval digest
scripts/terraform-exact-plan.sh \
  --root infrastructure/terraform/examples/aws \
  --action apply \
  --plan-out out/honua.tfplan \
  --var-file presets/small.tfvars.example \
  --actor "operator:jane@example.com" \
  --target-id "ecs:honua/prod" \
  --expires-in 3600

# 3. honua-devops#147 issues the approval bound to that digest

# 4. apply exactly that plan, or refuse
HONUA_IAC_REQUIRE_APPROVAL=1 scripts/terraform-exact-apply.sh \
  --plan out/honua.tfplan \
  --approved-digest "$APPROVED_DIGEST" \
  --receipt-out out/receipt.json
```

A destroy is the same sequence with `--action destroy`; the apply wrapper
refuses to run a destroy plan as an apply and vice versa.
