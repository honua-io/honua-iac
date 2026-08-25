#!/usr/bin/env bash
# Apply (or destroy) exactly one previously saved, approval-bound Terraform plan.
#
# This wrapper never regenerates a plan, never accepts variables, and never
# changes the init/backend/workspace/account context. It re-derives every bound
# fact from the live execution context and refuses before any mutation when one
# of them moved:
#
#   metadata-tampered        the metadata document no longer hashes to itself
#   approval-digest-mismatch the approval was issued for a different plan
#   approval-binding-missing an approval binding is required but was not supplied
#   action-mismatch          apply was asked to run a destroy plan (or vice versa)
#   plan-expired             the saved plan outlived its expiry
#   saved-plan-tampered      the .tfplan bytes no longer match the bound SHA-256
#   concurrent-claim         another executor holds this plan's claim
#   plan-already-claimed     the plan was already consumed (replay)
#   unqualified-plan-refused the plan was produced under a dev-only escape hatch
#   terraform-version-changed / provider-lock-changed / source-changed
#   backend-substituted / local-state-refused / lock-posture-missing
#   workspace-mismatch / account-mismatch / role-mismatch
#   long-lived-credential-refused
#   input-digest-changed
#   state-lineage-changed / state-serial-drift
#
# It writes an evidence-safe receipt either way: exit status, resulting state
# lineage/serial, output contract digest, actor and workload identity reference,
# backend step, and the cleanup/teardown handle. No secrets, no state contents.
#
# A refusal releases the claim -- nothing was mutated, so the same approved plan
# can be retried. An execution completes the claim whether Terraform succeeded or
# not: a failed apply may have mutated part of the stack, so the plan is spent
# and a fresh one must be produced and approved.
#
# Usage:
#   scripts/terraform-exact-apply.sh --plan <file> [options]
#
# Options:
#   --plan <file>              The exact saved binary plan to consume.
#   --metadata <file>          Plan metadata (default: <plan>.metadata.json).
#   --approved-digest <sha256> Approval binding issued by honua-devops#147.
#   --action apply|destroy     Operation the caller intends (default: from metadata).
#   --receipt-out <file>       Where to write the execution receipt.
#   --claim-dir <dir>          One-time claim directory (default: <plan>.claim).
#   --output-digest-name <n>   Output holding the contract digest
#                              (default: operator_contract_digest).
#   --allow-unqualified        Permit a plan produced with a dev-only escape hatch.
#   --dry-run                  Run every gate, then stop before mutating.
#   --claim-status             Print the claim state and exit. Use this to recover
#                              status after an ambiguous client disconnect.
#   --reclaim-after <seconds>  Take over a claim that was acquired but never
#                              completed after this many seconds. A COMPLETED
#                              claim is never reclaimed.
#
# Environment:
#   HONUA_IAC_TERRAFORM_BIN     terraform binary to use (default: terraform)
#   HONUA_IAC_REQUIRE_APPROVAL  when 1, refuse without --approved-digest
#   HONUA_IAC_OFFLINE=1         use fixtures instead of live AWS/state calls
#   HONUA_IAC_STS_FIXTURE       caller-identity fixture used when offline
#   HONUA_IAC_STATE_FIXTURE     pre-apply state fixture used when offline
#   HONUA_IAC_STATE_FIXTURE_AFTER post-apply state fixture used when offline

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/tf-exec-contract.sh
source "$SCRIPT_DIR/lib/tf-exec-contract.sh"

PLAN=""
METADATA_PATH=""
APPROVED_DIGEST=""
ACTION=""
RECEIPT_OUT=""
CLAIM_DIR=""
OUTPUT_DIGEST_NAME="operator_contract_digest"
ALLOW_UNQUALIFIED="false"
DRY_RUN="false"
CLAIM_STATUS_ONLY="false"
RECLAIM_AFTER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      PLAN="${2:-}"
      shift 2
      ;;
    --metadata)
      METADATA_PATH="${2:-}"
      shift 2
      ;;
    --approved-digest)
      APPROVED_DIGEST="${2:-}"
      shift 2
      ;;
    --action)
      ACTION="${2:-}"
      shift 2
      ;;
    --receipt-out)
      RECEIPT_OUT="${2:-}"
      shift 2
      ;;
    --claim-dir)
      CLAIM_DIR="${2:-}"
      shift 2
      ;;
    --output-digest-name)
      OUTPUT_DIGEST_NAME="${2:-}"
      shift 2
      ;;
    --allow-unqualified)
      ALLOW_UNQUALIFIED="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --claim-status)
      CLAIM_STATUS_ONLY="true"
      shift
      ;;
    --reclaim-after)
      RECLAIM_AFTER="${2:-0}"
      shift 2
      ;;
    -h | --help)
      # Print the contiguous comment header, so help never drifts out of sync
      # with the line numbers of this file.
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

[[ -n "$PLAN" ]] || usage_error "--plan is required"
require_cmd python3
require_cmd sha256sum

METADATA_PATH="${METADATA_PATH:-$PLAN.metadata.json}"
CLAIM_DIR="${CLAIM_DIR:-$PLAN.claim}"

# Status probe: answers "did my apply actually run?" after an ambiguous client
# disconnect, without touching the claim or the plan.
if [[ "$CLAIM_STATUS_ONLY" == "true" ]]; then
  claim_status "$CLAIM_DIR"
  exit 0
fi

[[ -f "$PLAN" ]] || refuse "saved-plan-missing" "saved plan not found: $PLAN"
[[ -f "$METADATA_PATH" ]] || refuse "plan-metadata-missing" "plan metadata not found: $METADATA_PATH"

METADATA="$(cat "$METADATA_PATH")"

# --- gate 1: the metadata document must hash to its own recorded digest -------
BOUND_METADATA_DIGEST="$(json_get "$METADATA" plan_metadata_digest)"
RECOMPUTED_METADATA_DIGEST="$(
  HONUA_IAC_JSON="$METADATA" python3 - <<'PY'
import hashlib
import json
import os

document = json.loads(os.environ["HONUA_IAC_JSON"])
document.pop("plan_metadata_digest", None)
canonical = json.dumps(document, sort_keys=True, separators=(",", ":")).encode("utf-8")
print(hashlib.sha256(canonical).hexdigest())
PY
)"
[[ -n "$BOUND_METADATA_DIGEST" ]] || refuse "metadata-tampered" "plan metadata carries no plan_metadata_digest"
if [[ "$BOUND_METADATA_DIGEST" != "$RECOMPUTED_METADATA_DIGEST" ]]; then
  refuse "metadata-tampered" \
    "plan metadata does not hash to its recorded digest (recorded $BOUND_METADATA_DIGEST, recomputed $RECOMPUTED_METADATA_DIGEST)"
fi

# --- gate 2: approval binding -------------------------------------------------
if [[ -n "$APPROVED_DIGEST" ]]; then
  if [[ "$APPROVED_DIGEST" != "$BOUND_METADATA_DIGEST" ]]; then
    refuse "approval-digest-mismatch" \
      "approval was issued for $APPROVED_DIGEST but this plan binds $BOUND_METADATA_DIGEST"
  fi
elif [[ "${HONUA_IAC_REQUIRE_APPROVAL:-0}" == "1" ]]; then
  refuse "approval-binding-missing" "HONUA_IAC_REQUIRE_APPROVAL=1 but no --approved-digest was supplied"
fi

# --- gate 3: action -----------------------------------------------------------
PLAN_ACTION="$(json_get "$METADATA" action)"
ACTION="${ACTION:-$PLAN_ACTION}"
assert_equal "action-mismatch" "action" "$PLAN_ACTION" "$ACTION"

# --- gate 4: expiry -----------------------------------------------------------
assert_not_expired "$(json_get "$METADATA" expires_at_utc)"

# --- gate 5: the saved plan bytes are the approved bytes ----------------------
assert_equal "saved-plan-tampered" "saved plan sha256" \
  "$(json_get "$METADATA" plan.sha256)" "$(sha256_file "$PLAN")"

# --- gate 6: posture ----------------------------------------------------------
RELEASE_QUALIFIED="$(json_get "$METADATA" posture.release_qualified)"
if [[ "$RELEASE_QUALIFIED" != "true" && "$ALLOW_UNQUALIFIED" != "true" ]]; then
  refuse "unqualified-plan-refused" \
    "plan was produced under a development escape hatch (local state, dirty source, or a non-STS credential); it cannot be applied on the certified path"
fi

# --- gate 7: one plan, one claim, one apply -----------------------------------
claim_acquire "$CLAIM_DIR" "$RECLAIM_AFTER"
trap 'claim_abandon "$CLAIM_DIR"' EXIT

# --- re-derive the live execution context ------------------------------------
ROOT_REL="$(json_get "$METADATA" source.terraform_root)"
ROOT="$REPO_ROOT/$ROOT_REL"
[[ -d "$ROOT" ]] || refuse "source-changed" "bound Terraform root no longer exists: $ROOT_REL"

assert_equal "terraform-version-changed" "terraform version" \
  "$(json_get "$METADATA" toolchain.terraform_version)" "$(terraform_version)"

assert_equal "provider-lock-changed" "provider lock digest" \
  "$(json_get "$METADATA" toolchain.provider_lock_digest)" "$(provider_lock_digest "$ROOT")"

# The bound revision is replayed as the explicit-revision fallback so a
# tarball operator re-derives the same tree digest; a changed tree still moves
# the digest and still refuses.
LIVE_SOURCE="$(iac_source_doc "$REPO_ROOT" "$ROOT" \
  "$(json_get "$METADATA" posture.dirty_source_allowed)" \
  "$(json_get "$METADATA" source.iac_revision)")"
assert_equal "source-changed" "iac revision" \
  "$(json_get "$METADATA" source.iac_revision)" "$(json_get "$LIVE_SOURCE" iac_revision)"
assert_equal "source-changed" "iac tree digest" \
  "$(json_get "$METADATA" source.iac_tree_digest)" "$(json_get "$LIVE_SOURCE" iac_tree_digest)"

BOUND_WORKSPACE="$(json_get "$METADATA" backend.workspace)"
LIVE_WORKSPACE="$(tf -chdir="$ROOT" workspace show 2>/dev/null || echo default)"
assert_equal "workspace-mismatch" "workspace" "$BOUND_WORKSPACE" "$LIVE_WORKSPACE"

LIVE_BACKEND="$(backend_identity_doc "$ROOT" "$LIVE_WORKSPACE")"
if [[ "$(json_get "$METADATA" posture.local_state_allowed)" != "true" ]]; then
  assert_remote_backend "$LIVE_BACKEND"
  assert_lock_primitive_supported "$LIVE_BACKEND" "$(terraform_version)"
fi
assert_equal "backend-substituted" "backend config digest" \
  "$(json_get "$METADATA" backend.backend_config_digest)" "$(printf '%s' "$LIVE_BACKEND" | json_digest)"

LIVE_IDENTITY="$(sts_identity_doc)"
if [[ "$(json_get "$METADATA" posture.local_state_allowed)" != "true" ]]; then
  assert_short_lived_identity "$LIVE_IDENTITY"
fi
assert_equal "account-mismatch" "aws account" \
  "$(json_get "$METADATA" identity.account_id)" "$(json_get "$LIVE_IDENTITY" account_id)"
assert_equal "role-mismatch" "assumed role arn" \
  "$(json_get "$METADATA" identity.assumed_role_arn)" "$(json_get "$LIVE_IDENTITY" arn)"

INPUT_REFS_FILES=()
while IFS= read -r ref; do
  [[ "$ref" == varfile:* ]] || continue
  INPUT_REFS_FILES+=("${ref#varfile:}")
done < <(
  HONUA_IAC_JSON="$METADATA" python3 -c '
import json, os
for ref in json.loads(os.environ["HONUA_IAC_JSON"])["inputs"]["input_refs"]:
    print(ref)
'
)
assert_equal "input-digest-changed" "input digest" \
  "$(json_get "$METADATA" inputs.input_digest)" \
  "$(json_get "$(input_digest_doc "$ROOT" "${INPUT_REFS_FILES[@]+"${INPUT_REFS_FILES[@]}"}")" input_digest)"

STATE_NOW="$(state_lineage_doc "$ROOT")"
assert_equal "state-lineage-changed" "state lineage" \
  "$(json_get "$METADATA" state_before.lineage)" "$(json_get "$STATE_NOW" lineage)"
assert_equal "state-serial-drift" "state serial" \
  "$(json_get "$METADATA" state_before.serial)" "$(json_get "$STATE_NOW" serial)"

log_info "all bindings verified for $BOUND_METADATA_DIGEST"

if [[ "$DRY_RUN" == "true" ]]; then
  log_info "--dry-run: every gate passed; stopping before mutation"
  exit 0
fi

# --- execute exactly the saved plan ------------------------------------------
set +e
tf -chdir="$ROOT" apply -input=false -no-color -lock-timeout=120s "$PLAN"
APPLY_EXIT=$?
set -e

if [[ "$APPLY_EXIT" -ne 0 ]]; then
  # The claim is still completed below. A failed apply may have mutated part of
  # the stack, so this plan is spent: read state_after from the receipt, then
  # produce and approve a fresh plan.
  log_error "terraform apply exited $APPLY_EXIT; the plan is spent, recording a failed receipt"
fi

# --- post-execution evidence --------------------------------------------------
if [[ "${HONUA_IAC_OFFLINE:-0}" == "1" && -n "${HONUA_IAC_STATE_FIXTURE_AFTER:-}" ]]; then
  export HONUA_IAC_STATE_FIXTURE="$HONUA_IAC_STATE_FIXTURE_AFTER"
fi
STATE_AFTER="$(state_lineage_doc "$ROOT")"

OUTPUT_CONTRACT_DIGEST=""
if [[ "$APPLY_EXIT" -eq 0 && "$ACTION" == "apply" ]]; then
  # Only the named digest output is read. `terraform output -json` would expose
  # sensitive values, so it is never invoked here.
  OUTPUT_CONTRACT_DIGEST="$(tf -chdir="$ROOT" output -raw "$OUTPUT_DIGEST_NAME" 2>/dev/null || echo "")"
fi

claim_complete "$CLAIM_DIR"
trap - EXIT

RECEIPT="$(
  HONUA_IAC_METADATA="$METADATA" \
    HONUA_IAC_STATE_AFTER="$STATE_AFTER" \
    HONUA_IAC_IDENTITY_DOC="$LIVE_IDENTITY" \
    HONUA_IAC_APPLY_EXIT="$APPLY_EXIT" \
    HONUA_IAC_OUTPUT_DIGEST="$OUTPUT_CONTRACT_DIGEST" \
    HONUA_IAC_OUTPUT_DIGEST_NAME="$OUTPUT_DIGEST_NAME" \
    HONUA_IAC_CLAIM_DIR="$CLAIM_DIR" \
    HONUA_IAC_PLAN_PATH="$PLAN" \
    HONUA_IAC_APPROVED_DIGEST="$APPROVED_DIGEST" \
    HONUA_IAC_COMPLETED_AT="$(utc_now)" \
    python3 - <<'PY'
import json
import os
import sys

metadata = json.loads(os.environ["HONUA_IAC_METADATA"])
identity = json.loads(os.environ["HONUA_IAC_IDENTITY_DOC"])
exit_code = int(os.environ["HONUA_IAC_APPLY_EXIT"])

receipt = {
    "schema_version": "v1",
    "kind": "honua.iac.exec-receipt",
    "action": metadata["action"],
    "completed_at_utc": os.environ["HONUA_IAC_COMPLETED_AT"],
    "exit_status": exit_code,
    "status": "succeeded" if exit_code == 0 else "failed",
    "plan_metadata_digest": metadata["plan_metadata_digest"],
    "approved_digest": os.environ.get("HONUA_IAC_APPROVED_DIGEST") or None,
    "saved_plan_sha256": metadata["plan"]["sha256"],
    "actor_id": metadata.get("actor_id"),
    "target_id": metadata.get("target_id"),
    "candidate_digest": metadata.get("candidate_digest"),
    "workload_identity": {
        "assumed_role_arn": identity.get("arn"),
        "role_id": identity.get("role_id"),
        "account_id": identity.get("account_id"),
        "partition": identity.get("partition"),
        "issuer": identity.get("issuer"),
        "credential_kind": identity.get("credential_kind"),
        "contract_digest": metadata.get("workload_identity_contract_digest"),
    },
    "backend_step": {
        "backend_config_digest": metadata["backend"]["backend_config_digest"],
        "backend_kind": metadata["backend"]["backend_kind"],
        "workspace": metadata["backend"]["workspace"],
        "object_key": metadata["backend"]["object_key"],
        "bucket_arn": metadata["backend"]["bucket_arn"],
        "locking": metadata["backend"]["locking"],
    },
    "state_before": metadata["state_before"],
    "state_after": json.loads(os.environ["HONUA_IAC_STATE_AFTER"]),
    "output_contract": {
        "output_name": os.environ["HONUA_IAC_OUTPUT_DIGEST_NAME"],
        "digest": os.environ.get("HONUA_IAC_OUTPUT_DIGEST") or None,
    },
    "cleanup": {
        "claim_dir": os.environ["HONUA_IAC_CLAIM_DIR"],
        "saved_plan": os.environ["HONUA_IAC_PLAN_PATH"],
        "teardown_root": metadata["source"]["terraform_root"],
        "teardown_action": "destroy",
    },
    "evidence_scope": "metadata-only-post-execution",
}
json.dump(receipt, sys.stdout, sort_keys=True, separators=(",", ":"), indent=2)
sys.stdout.write("\n")
PY
)"

printf '%s\n' "$RECEIPT"
if [[ -n "$RECEIPT_OUT" ]]; then
  printf '%s\n' "$RECEIPT" >"$RECEIPT_OUT"
  log_info "execution receipt written to $RECEIPT_OUT"
fi

exit "$APPLY_EXIT"
