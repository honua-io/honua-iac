#!/usr/bin/env bash
# Emit the evidence-safe backend identity for an initialized Terraform root.
#
# Prints a canonical JSON document describing WHERE state lives and HOW it is
# protected: AWS account and partition, region, bucket id/ARN, object key,
# workspace, locking primitive, encryption/KMS reference, the backend access
# role, and a canonical digest over all of it. It prints no credentials, no
# tokens, and no Terraform state contents -- backend config keys that could
# carry a secret are recorded as redacted key names only, which still moves the
# digest when they change.
#
# honua-devops#147 binds an approval to `backend_config_digest`. A later apply
# whose backend resolves to a different bucket, key, region, lock table, or role
# produces a different digest and is refused before any mutation.
#
# Usage:
#   scripts/terraform-backend-identity.sh --root <terraform-root> [options]
#
# Options:
#   --root <dir>          Terraform root that has already been `terraform init`ed.
#   --workspace <name>    Workspace to report (default: the root's current one).
#   --output <file>       Write the document here as well as to stdout.
#   --allow-local-state   Do not refuse local state. Disposable development only;
#                         the emitted document is stamped release_qualified=false.
#   --no-identity         Skip the STS lookup (no account id in the document).
#
# Environment:
#   HONUA_IAC_TERRAFORM_BIN   terraform binary to use (default: terraform)
#   HONUA_IAC_OFFLINE=1       use fixtures instead of live AWS/state calls
#   HONUA_IAC_STS_FIXTURE     caller-identity fixture used when offline

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tf-exec-contract.sh
source "$SCRIPT_DIR/lib/tf-exec-contract.sh"

ROOT=""
WORKSPACE=""
OUTPUT=""
ALLOW_LOCAL_STATE="false"
WITH_IDENTITY="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT="${2:-}"
      shift 2
      ;;
    --workspace)
      WORKSPACE="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT="${2:-}"
      shift 2
      ;;
    --allow-local-state)
      ALLOW_LOCAL_STATE="true"
      shift
      ;;
    --no-identity)
      WITH_IDENTITY="false"
      shift
      ;;
    -h | --help)
      sed -n '2,30p' "${BASH_SOURCE[0]}"
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

require_cmd python3
require_cmd sha256sum

if [[ -z "$WORKSPACE" ]]; then
  WORKSPACE="$(tf -chdir="$ROOT" workspace show 2>/dev/null || echo default)"
fi

BACKEND_DOC="$(backend_identity_doc "$ROOT" "$WORKSPACE")"

if [[ "$ALLOW_LOCAL_STATE" != "true" ]]; then
  assert_remote_backend "$BACKEND_DOC"
  assert_lock_primitive_supported "$BACKEND_DOC" "$(terraform_version)"
fi

IDENTITY_DOC='null'
if [[ "$WITH_IDENTITY" == "true" ]]; then
  IDENTITY_DOC="$(sts_identity_doc)"
fi

DOCUMENT="$(
  HONUA_IAC_BACKEND_DOC="$BACKEND_DOC" \
    HONUA_IAC_IDENTITY_DOC="$IDENTITY_DOC" \
    HONUA_IAC_ALLOW_LOCAL="$ALLOW_LOCAL_STATE" \
    HONUA_IAC_TF_VERSION="$(terraform_version)" \
    python3 - <<'PY'
import hashlib
import json
import os
import sys

backend = json.loads(os.environ["HONUA_IAC_BACKEND_DOC"])
identity = json.loads(os.environ["HONUA_IAC_IDENTITY_DOC"])

backend["account"] = {
    "account_id": (identity or {}).get("account_id"),
    "partition": (identity or {}).get("partition", "aws"),
}
backend["terraform_version"] = os.environ["HONUA_IAC_TF_VERSION"]
backend["release_qualified"] = bool(
    backend["is_remote"] and backend["locking"]["kind"] != "none"
)
backend["local_state_allowed"] = os.environ["HONUA_IAC_ALLOW_LOCAL"] == "true"

canonical = json.dumps(backend, sort_keys=True, separators=(",", ":")).encode("utf-8")
backend["backend_config_digest"] = hashlib.sha256(canonical).hexdigest()

json.dump(backend, sys.stdout, sort_keys=True, separators=(",", ":"), indent=2)
sys.stdout.write("\n")
PY
)"

printf '%s\n' "$DOCUMENT"

if [[ -n "$OUTPUT" ]]; then
  printf '%s\n' "$DOCUMENT" >"$OUTPUT"
  log_info "backend identity written to $OUTPUT"
fi
