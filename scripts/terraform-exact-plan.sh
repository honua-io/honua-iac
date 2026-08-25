#!/usr/bin/env bash
# Produce an exact, approvable Terraform plan: one saved binary plan plus the
# canonical machine-readable metadata that binds it to a single execution
# context.
#
# The metadata pins the Terraform root and IaC revision, the Terraform version
# and provider lock digest, the backend config digest, the input digest, the
# target account/region, the workspace and object key, the prior state
# lineage/serial, the action, an expiry, and the SHA-256 of the saved plan
# itself. `plan_metadata_digest` over that canonical document is what
# honua-devops#147 binds an approval to.
#
# Nothing secret is recorded: variable values are hashed, state is reduced to
# lineage+serial before it leaves the pipe, and backend credentials appear only
# as redacted key names.
#
# Usage:
#   scripts/terraform-exact-plan.sh --root <dir> --action apply|destroy [options]
#
# Required:
#   --root <dir>                    Terraform root to plan.
#
# Options:
#   --action apply|destroy          Operation the plan authorizes (default: apply).
#   --plan-out <file>               Saved binary plan (default: <root>/honua.tfplan).
#   --metadata-out <file>           Metadata JSON (default: <plan-out>.metadata.json).
#   --var-file <file>               Passed to terraform plan; repeatable.
#   --workspace <name>              Workspace to select before planning.
#   --expires-in <seconds>          Plan lifetime (default: 3600, max: 86400).
#   --actor <id>                    Identified human/workload actor for the receipt.
#   --target-id <id>                Deployment target id recorded in the metadata.
#   --candidate-digest <sha256>     Release candidate digest to bind.
#   --workload-identity-digest <d>  Digest of the workload identity contract.
#   --skip-init                     Do not run terraform init (already initialized).
#   --iac-revision <rev>            Release revision to pin when the tree carries no
#                                   git metadata (the distribution tarball).
#   --allow-dirty-source            Permit uncommitted IaC. Disposable dev only.
#   --allow-local-state             Permit local state. Disposable dev only; the
#                                   metadata is stamped release_qualified=false.
#
# Environment:
#   HONUA_IAC_TERRAFORM_BIN   terraform binary to use (default: terraform)
#   HONUA_IAC_OFFLINE=1       use fixtures instead of live AWS/state calls
#   HONUA_IAC_STS_FIXTURE     caller-identity fixture used when offline
#   HONUA_IAC_STATE_FIXTURE   state metadata fixture used when offline

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/tf-exec-contract.sh
source "$SCRIPT_DIR/lib/tf-exec-contract.sh"

ROOT=""
ACTION="apply"
PLAN_OUT=""
METADATA_OUT=""
WORKSPACE=""
EXPIRES_IN=3600
ACTOR="${HONUA_IAC_ACTOR:-unspecified}"
TARGET_ID=""
CANDIDATE_DIGEST=""
WORKLOAD_IDENTITY_DIGEST=""
SKIP_INIT="false"
ALLOW_DIRTY="false"
ALLOW_LOCAL_STATE="false"
IAC_REVISION=""
VAR_FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT="${2:-}"
      shift 2
      ;;
    --action)
      ACTION="${2:-}"
      shift 2
      ;;
    --plan-out)
      PLAN_OUT="${2:-}"
      shift 2
      ;;
    --metadata-out)
      METADATA_OUT="${2:-}"
      shift 2
      ;;
    --var-file)
      VAR_FILES+=("${2:-}")
      shift 2
      ;;
    --workspace)
      WORKSPACE="${2:-}"
      shift 2
      ;;
    --expires-in)
      EXPIRES_IN="${2:-}"
      shift 2
      ;;
    --actor)
      ACTOR="${2:-}"
      shift 2
      ;;
    --target-id)
      TARGET_ID="${2:-}"
      shift 2
      ;;
    --candidate-digest)
      CANDIDATE_DIGEST="${2:-}"
      shift 2
      ;;
    --workload-identity-digest)
      WORKLOAD_IDENTITY_DIGEST="${2:-}"
      shift 2
      ;;
    --skip-init)
      SKIP_INIT="true"
      shift
      ;;
    --iac-revision)
      IAC_REVISION="${2:-}"
      shift 2
      ;;
    --allow-dirty-source)
      ALLOW_DIRTY="true"
      shift
      ;;
    --allow-local-state)
      ALLOW_LOCAL_STATE="true"
      shift
      ;;
    -h | --help)
      sed -n '2,46p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

[[ -n "$ROOT" ]] || usage_error "--root is required"
[[ -d "$ROOT" ]] || usage_error "terraform root not found: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"

case "$ACTION" in
  apply | destroy) ;;
  *) usage_error "--action must be 'apply' or 'destroy'" ;;
esac

[[ "$EXPIRES_IN" =~ ^[0-9]+$ ]] || usage_error "--expires-in must be a whole number of seconds"
((EXPIRES_IN > 0 && EXPIRES_IN <= 86400)) || usage_error "--expires-in must be between 1 and 86400 seconds"

PLAN_OUT="${PLAN_OUT:-$ROOT/honua.tfplan}"
METADATA_OUT="${METADATA_OUT:-$PLAN_OUT.metadata.json}"

require_cmd python3
require_cmd sha256sum

TF_VERSION="$(terraform_version)"
log_info "terraform $TF_VERSION; root $ROOT; action $ACTION"

# --- 1. initialize (never creates the backend; bootstrap/aws-tfstate does that)
if [[ "$SKIP_INIT" != "true" ]]; then
  log_info "terraform init"
  tf -chdir="$ROOT" init -input=false -no-color >/dev/null ||
    refuse "init-failed" "terraform init failed for $ROOT"
fi

# --- 2. workspace
if [[ -n "$WORKSPACE" ]]; then
  tf -chdir="$ROOT" workspace select "$WORKSPACE" >/dev/null 2>&1 ||
    tf -chdir="$ROOT" workspace new "$WORKSPACE" >/dev/null 2>&1 ||
    refuse "workspace-unavailable" "cannot select workspace $WORKSPACE"
else
  WORKSPACE="$(tf -chdir="$ROOT" workspace show 2>/dev/null || echo default)"
fi

# --- 3. backend identity; local state is refused on the certified path
BACKEND_DOC="$(backend_identity_doc "$ROOT" "$WORKSPACE")"
if [[ "$ALLOW_LOCAL_STATE" == "true" ]]; then
  log_warn "local state permitted by --allow-local-state; this plan can never satisfy the release lane"
else
  assert_remote_backend "$BACKEND_DOC"
  assert_lock_primitive_supported "$BACKEND_DOC" "$TF_VERSION"
fi
BACKEND_DIGEST="$(printf '%s' "$BACKEND_DOC" | json_digest)"

# --- 4. short-lived execution identity
IDENTITY_DOC="$(sts_identity_doc)"
if [[ "$ALLOW_LOCAL_STATE" != "true" ]]; then
  assert_short_lived_identity "$IDENTITY_DOC"
fi

# --- 5. prior state lineage/serial (metadata only; state contents never stored)
STATE_BEFORE="$(state_lineage_doc "$ROOT")"
log_info "state lineage before plan: $(json_get "$STATE_BEFORE" lineage) serial $(json_get "$STATE_BEFORE" serial)"

# --- 6. immutable source + toolchain pinning
SOURCE_DOC="$(iac_source_doc "$REPO_ROOT" "$ROOT" "$ALLOW_DIRTY" "$IAC_REVISION")"
LOCK_DIGEST="$(provider_lock_digest "$ROOT")"

# --- 7. inputs (values hashed, never recorded)
INPUT_DOC="$(input_digest_doc "$ROOT" "${VAR_FILES[@]+"${VAR_FILES[@]}"}")"

# --- 8. the saved binary plan itself
PLAN_ARGS=(-chdir="$ROOT" plan -input=false -no-color -lock-timeout=120s -out="$PLAN_OUT")
[[ "$ACTION" == "destroy" ]] && PLAN_ARGS+=(-destroy)
for vf in "${VAR_FILES[@]+"${VAR_FILES[@]}"}"; do
  PLAN_ARGS+=("-var-file=$vf")
done

log_info "terraform plan -out=$PLAN_OUT"
tf "${PLAN_ARGS[@]}" ||
  refuse "plan-failed" "terraform plan failed; no approvable artifact was produced"

PLAN_SHA256="$(sha256_file "$PLAN_OUT")"

# --- 9. canonical metadata + binding digest
CREATED_AT="$(utc_now)"
EXPIRES_AT="$(date -u -d "+${EXPIRES_IN} seconds" +%Y-%m-%dT%H:%M:%SZ)"

METADATA="$(
  HONUA_IAC_BACKEND_DOC="$BACKEND_DOC" \
    HONUA_IAC_BACKEND_DIGEST="$BACKEND_DIGEST" \
    HONUA_IAC_IDENTITY_DOC="$IDENTITY_DOC" \
    HONUA_IAC_STATE_BEFORE="$STATE_BEFORE" \
    HONUA_IAC_SOURCE_DOC="$SOURCE_DOC" \
    HONUA_IAC_INPUT_DOC="$INPUT_DOC" \
    HONUA_IAC_ACTION="$ACTION" \
    HONUA_IAC_ACTOR="$ACTOR" \
    HONUA_IAC_TARGET_ID="$TARGET_ID" \
    HONUA_IAC_CANDIDATE_DIGEST="$CANDIDATE_DIGEST" \
    HONUA_IAC_WORKLOAD_DIGEST="$WORKLOAD_IDENTITY_DIGEST" \
    HONUA_IAC_PLAN_PATH="$PLAN_OUT" \
    HONUA_IAC_PLAN_SHA256="$PLAN_SHA256" \
    HONUA_IAC_TF_VERSION="$TF_VERSION" \
    HONUA_IAC_LOCK_DIGEST="$LOCK_DIGEST" \
    HONUA_IAC_WORKSPACE="$WORKSPACE" \
    HONUA_IAC_CREATED_AT="$CREATED_AT" \
    HONUA_IAC_EXPIRES_AT="$EXPIRES_AT" \
    HONUA_IAC_ALLOW_LOCAL="$ALLOW_LOCAL_STATE" \
    HONUA_IAC_ALLOW_DIRTY="$ALLOW_DIRTY" \
    python3 - <<'PY'
import hashlib
import json
import os
import sys


def env(name, default=None):
    value = os.environ.get(name, "")
    return value if value else default


backend = json.loads(os.environ["HONUA_IAC_BACKEND_DOC"])
identity = json.loads(os.environ["HONUA_IAC_IDENTITY_DOC"])
state_before = json.loads(os.environ["HONUA_IAC_STATE_BEFORE"])
source = json.loads(os.environ["HONUA_IAC_SOURCE_DOC"])
inputs = json.loads(os.environ["HONUA_IAC_INPUT_DOC"])

allow_local = os.environ["HONUA_IAC_ALLOW_LOCAL"] == "true"
allow_dirty = os.environ["HONUA_IAC_ALLOW_DIRTY"] == "true"

document = {
    "schema_version": "v1",
    "kind": "honua.iac.exact-plan",
    "action": os.environ["HONUA_IAC_ACTION"],
    "created_at_utc": os.environ["HONUA_IAC_CREATED_AT"],
    "expires_at_utc": os.environ["HONUA_IAC_EXPIRES_AT"],
    "actor_id": env("HONUA_IAC_ACTOR", "unspecified"),
    "target_id": env("HONUA_IAC_TARGET_ID"),
    "candidate_digest": env("HONUA_IAC_CANDIDATE_DIGEST"),
    "workload_identity_contract_digest": env("HONUA_IAC_WORKLOAD_DIGEST"),
    "source": source,
    "toolchain": {
        "terraform_version": os.environ["HONUA_IAC_TF_VERSION"],
        "provider_lock_digest": os.environ["HONUA_IAC_LOCK_DIGEST"],
    },
    "backend": {
        "backend_config_digest": os.environ["HONUA_IAC_BACKEND_DIGEST"],
        "backend_kind": backend["backend_kind"],
        "is_remote": backend["is_remote"],
        "workspace": os.environ["HONUA_IAC_WORKSPACE"],
        "object_key": backend["location"]["object_key"],
        "region": backend["location"]["region"],
        "bucket_id": backend["location"]["bucket_id"],
        "bucket_arn": backend["location"]["bucket_arn"],
        "locking": backend["locking"],
        "encryption": backend["encryption"],
        "backend_access_role_arn": backend["backend_access_role_arn"],
    },
    "identity": {
        "account_id": identity.get("account_id"),
        "partition": identity.get("partition"),
        "assumed_role_arn": identity.get("arn"),
        "role_id": identity.get("role_id"),
        "issuer": identity.get("issuer"),
        "session_expires_at_utc": identity.get("session_expires_at_utc"),
        "credential_kind": identity.get("credential_kind"),
        "evidence_mode": identity.get("evidence_mode"),
    },
    "inputs": inputs,
    "state_before": state_before,
    "plan": {
        "path": os.path.basename(os.environ["HONUA_IAC_PLAN_PATH"]),
        "sha256": os.environ["HONUA_IAC_PLAN_SHA256"],
    },
    "posture": {
        "release_qualified": bool(
            backend["is_remote"]
            and backend["locking"]["kind"] != "none"
            and not allow_local
            and not allow_dirty
            and identity.get("credential_kind") == "sts-assumed-role"
            and identity.get("evidence_mode") == "live"
        ),
        "local_state_allowed": allow_local,
        "dirty_source_allowed": allow_dirty,
    },
    "qualification_status": "unqualified",
    "evidence_scope": "metadata-only-pre-apply",
}

canonical = json.dumps(document, sort_keys=True, separators=(",", ":")).encode("utf-8")
document["plan_metadata_digest"] = hashlib.sha256(canonical).hexdigest()

json.dump(document, sys.stdout, sort_keys=True, separators=(",", ":"), indent=2)
sys.stdout.write("\n")
PY
)"

printf '%s\n' "$METADATA" >"$METADATA_OUT"
PLAN_METADATA_DIGEST="$(printf '%s' "$METADATA" | python3 -c 'import json,sys; print(json.load(sys.stdin)["plan_metadata_digest"])')"
printf '%s\n' "$PLAN_METADATA_DIGEST" >"$METADATA_OUT.digest"

log_info "saved plan:      $PLAN_OUT (sha256 $PLAN_SHA256)"
log_info "plan metadata:   $METADATA_OUT"
log_info "approval digest: $PLAN_METADATA_DIGEST"
log_info "expires at:      $EXPIRES_AT"
