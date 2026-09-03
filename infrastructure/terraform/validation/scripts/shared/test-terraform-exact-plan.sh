#!/usr/bin/env bash
# Regression suite for the governed Terraform execution substrate (honua-iac#149).
#
# The scripts under test decide whether a mutation of a customer's cloud account
# is allowed to start, so their refusal rules are the thing being tested. The
# suite runs entirely offline against a synthetic git repository, a fake
# `terraform` binary, and caller-identity/state fixtures: no AWS credentials, no
# network, no real state.
#
# Coverage:
#   positive  plan -> metadata + approval digest, dry-run gate pass, apply +
#             receipt with post-execution state lineage and output digest
#   negative  every entry in the fail-closed matrix documented in
#             docs/devops/terraform-exact-plan-contract.md
#
# Usage: ./test-terraform-exact-plan.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

command -v python3 >/dev/null 2>&1 || {
  echo "[ERROR] python3 is required" >&2
  exit 1
}

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

# --- fake terraform ----------------------------------------------------------
# Understands only the subcommands the wrappers actually invoke. Behaviour is
# steered by FAKE_TF_* environment variables so a case can move the version,
# workspace, plan bytes, or apply exit code.
cat >"$FAKE_BIN/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

chdir=""
args=()
for arg in "$@"; do
  case "$arg" in
    -chdir=*) chdir="${arg#-chdir=}" ;;
    *) args+=("$arg") ;;
  esac
done

cmd="${args[0]:-}"
case "$cmd" in
  version)
    printf '{"terraform_version":"%s"}\n' "${FAKE_TF_VERSION:-1.10.5}"
    ;;
  init)
    exit "${FAKE_TF_INIT_EXIT:-0}"
    ;;
  workspace)
    case "${args[1]:-}" in
      show) printf '%s\n' "${FAKE_TF_WORKSPACE:-default}" ;;
      select | new) exit "${FAKE_TF_WORKSPACE_EXIT:-0}" ;;
      *) exit 1 ;;
    esac
    ;;
  plan)
    out=""
    for arg in "${args[@]}"; do
      case "$arg" in -out=*) out="${arg#-out=}" ;; esac
    done
    [[ -n "$out" ]] || exit 1
    printf '%s' "${FAKE_TF_PLAN_BYTES:-honua-fake-plan-bytes}" > "$out"
    exit "${FAKE_TF_PLAN_EXIT:-0}"
    ;;
  apply)
    [[ -n "${FAKE_TF_APPLY_START_LOG:-}" ]] && printf '%s\n' "$$" >>"$FAKE_TF_APPLY_START_LOG"
    [[ "${FAKE_TF_APPLY_WAIT:-0}" == "1" ]] && while :; do sleep 1; done
    printf 'fake terraform apply of %s\n' "${args[*]}"
    exit "${FAKE_TF_APPLY_EXIT:-0}"
    ;;
  output)
    printf '%s\n' "${FAKE_TF_OUTPUT_DIGEST:-}"
    ;;
  state)
    cat "${FAKE_TF_STATE_FILE:-/dev/null}"
    ;;
  *)
    echo "fake terraform: unsupported command $cmd" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/terraform"

# --- synthetic repository ----------------------------------------------------
BASE="$TMP_DIR/base"
STACK_REL="infrastructure/terraform/examples/fake-stack"
mkdir -p "$BASE/$STACK_REL/.terraform" "$BASE/scripts" "$BASE/fixtures" "$BASE/artifacts"

cp -a "$REPO_ROOT/scripts/lib" "$BASE/scripts/lib"
cp "$REPO_ROOT/scripts/terraform-exact-plan.sh" \
  "$REPO_ROOT/scripts/terraform-exact-apply.sh" \
  "$REPO_ROOT/scripts/terraform-backend-identity.sh" \
  "$BASE/scripts/"
chmod +x "$BASE/scripts"/*.sh

cat >"$BASE/.gitignore" <<'EOF'
.terraform/
artifacts/
*.tfplan
runtime.auto.tfvars
EOF

cat >"$BASE/$STACK_REL/main.tf" <<'EOF'
# Synthetic stack used only by the exact-plan regression suite.
locals {
  fake = "stack"
}
EOF

cat >"$BASE/$STACK_REL/.terraform.lock.hcl" <<'EOF'
provider "registry.terraform.io/hashicorp/aws" {
  version     = "6.61.0"
  constraints = "6.61.0"
}
EOF

write_backend_state() {
  local target="$1"
  local bucket="${2:-honua-tfstate-fixture}"
  cat >"$target/.terraform/terraform.tfstate" <<EOF
{
  "version": 3,
  "backend": {
    "type": "s3",
    "config": {
      "bucket": "$bucket",
      "key": "honua/aws/prod/terraform.tfstate",
      "region": "us-east-1",
      "encrypt": true,
      "use_lockfile": true,
      "kms_key_id": "arn:aws:kms:us-east-1:123456789012:key/fixture",
      "access_key": null,
      "secret_key": null
    }
  }
}
EOF
}
write_backend_state "$BASE/$STACK_REL"

cat >"$BASE/fixtures/sts.json" <<'EOF'
{
  "Account": "123456789012",
  "Arn": "arn:aws:sts::123456789012:assumed-role/honua-deploy-prod/session",
  "UserId": "AROAEXAMPLEID:session",
  "Issuer": "https://token.actions.githubusercontent.com",
  "SessionExpiresAtUtc": "2099-01-01T00:00:00Z"
}
EOF

cat >"$BASE/fixtures/sts-iam-user.json" <<'EOF'
{
  "Account": "123456789012",
  "Arn": "arn:aws:iam::123456789012:user/honua-terraform",
  "UserId": "AIDAEXAMPLEID"
}
EOF

cat >"$BASE/fixtures/sts-other-account.json" <<'EOF'
{
  "Account": "999988887777",
  "Arn": "arn:aws:sts::999988887777:assumed-role/honua-deploy-prod/session",
  "UserId": "AROAEXAMPLEID:session",
  "Issuer": "https://token.actions.githubusercontent.com"
}
EOF

cat >"$BASE/fixtures/sts-other-role.json" <<'EOF'
{
  "Account": "123456789012",
  "Arn": "arn:aws:sts::123456789012:assumed-role/honua-admin-breakglass/session",
  "UserId": "AROAOTHERID:session",
  "Issuer": "https://token.actions.githubusercontent.com"
}
EOF

cat >"$BASE/fixtures/state-before.json" <<'EOF'
{ "lineage": "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9", "serial": 12, "resources": ["never-recorded"] }
EOF

cat >"$BASE/fixtures/state-after.json" <<'EOF'
{ "lineage": "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9", "serial": 13, "resources": ["never-recorded"] }
EOF

cat >"$BASE/fixtures/state-substituted.json" <<'EOF'
{ "lineage": "ffffffff-4e5f-6071-8293-a4b5c6d7e8f9", "serial": 12 }
EOF

cat >"$BASE/fixtures/state-drifted.json" <<'EOF'
{ "lineage": "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9", "serial": 44 }
EOF

cat >"$BASE/$STACK_REL/prod.tfvars" <<'EOF'
environment = "prod"
EOF

# Untracked-but-gitignored input file: changing it moves the input digest without
# moving the source tree digest, which is what isolates the input-digest gate
# from the source-changed gate.
cat >"$BASE/$STACK_REL/runtime.auto.tfvars" <<'EOF'
desired_count = 1
EOF

git -C "$BASE" init -q
git -C "$BASE" config user.email "test@honua.io"
git -C "$BASE" config user.name "Honua Test"
git -C "$BASE" add -A
git -C "$BASE" -c commit.gpgsign=false commit -qm "fixture"

# --- harness -----------------------------------------------------------------

PASS_COUNT=0
FAIL_COUNT=0

new_case() {
  local name="$1"
  local dir="$TMP_DIR/case-$name"
  rm -rf "$dir"
  cp -a "$BASE" "$dir"
  printf '%s' "$dir"
}

run_plan() {
  local dir="$1"
  shift
  set +e
  PATH="$FAKE_BIN:$PATH" \
    HONUA_IAC_OFFLINE=1 \
    HONUA_IAC_STS_FIXTURE="${STS_FIXTURE:-$dir/fixtures/sts.json}" \
    HONUA_IAC_STATE_FIXTURE="${STATE_FIXTURE:-$dir/fixtures/state-before.json}" \
    "$dir/scripts/terraform-exact-plan.sh" \
    --root "$dir/$STACK_REL" \
    --plan-out "$dir/artifacts/honua.tfplan" \
    --actor "operator:test" \
    --target-id "ecs:honua/prod" \
    "$@" >"$dir/plan.log" 2>&1
  LAST_EXIT=$?
  set -e
  LAST_LOG="$dir/plan.log"
}

run_apply() {
  local dir="$1"
  shift
  set +e
  PATH="$FAKE_BIN:$PATH" \
    HONUA_IAC_OFFLINE=1 \
    HONUA_IAC_STS_FIXTURE="${STS_FIXTURE:-$dir/fixtures/sts.json}" \
    HONUA_IAC_STATE_FIXTURE="${STATE_FIXTURE:-$dir/fixtures/state-before.json}" \
    HONUA_IAC_STATE_FIXTURE_AFTER="${STATE_FIXTURE_AFTER:-$dir/fixtures/state-after.json}" \
    "$dir/scripts/terraform-exact-apply.sh" \
    --plan "$dir/artifacts/honua.tfplan" \
    "$@" >"$dir/apply.log" 2>&1
  LAST_EXIT=$?
  set -e
  LAST_LOG="$dir/apply.log"
}

expect_refusal() {
  local label="$1"
  local reason="$2"
  if [[ "$LAST_EXIT" -eq 0 ]]; then
    echo "[FAIL] $label: expected refusal '$reason' but the command succeeded" >&2
    sed -n '1,40p' "$LAST_LOG" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi
  if ! grep -q "REFUSED\[$reason\]" "$LAST_LOG"; then
    echo "[FAIL] $label: expected reason '$reason'" >&2
    sed -n '1,40p' "$LAST_LOG" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi
  echo "[PASS] $label -> $reason"
  PASS_COUNT=$((PASS_COUNT + 1))
}

expect_success() {
  local label="$1"
  if [[ "$LAST_EXIT" -ne 0 ]]; then
    echo "[FAIL] $label: expected success, got exit $LAST_EXIT" >&2
    sed -n '1,40p' "$LAST_LOG" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi
  echo "[PASS] $label"
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_json() {
  local label="$1"
  local file="$2"
  local expr="$3"
  if python3 - "$file" "$expr" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    doc = json.load(handle)
sys.exit(0 if eval(sys.argv[2], {"doc": doc, "json": json, "len": len, "all": all}) else 1)
PY
  then
    echo "[PASS] $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "[FAIL] $label: assertion failed -> $expr" >&2
    cat "$file" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# assert_schema <label> <document> <schema>
#
# Uses jsonschema when it is importable and falls back to a required-keys check
# so the suite still guards the contract on a bare runner.
assert_schema() {
  local label="$1"
  local document="$2"
  local schema="$3"
  if python3 - "$document" "$schema" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    document = json.load(handle)
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    schema = json.load(handle)

try:
    import jsonschema
except ImportError:
    missing = [key for key in schema.get("required", []) if key not in document]
    if missing:
        print("missing required keys: %s" % ", ".join(missing), file=sys.stderr)
        sys.exit(1)
    extra = []
    if schema.get("additionalProperties") is False:
        allowed = set(schema.get("properties", {}))
        extra = sorted(set(document) - allowed)
    if extra:
        print("unexpected keys: %s" % ", ".join(extra), file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

try:
    jsonschema.validate(instance=document, schema=schema)
except jsonschema.ValidationError as error:
    print("%s" % error.message, file=sys.stderr)
    sys.exit(1)
PY
  then
    echo "[PASS] $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "[FAIL] $label: document does not satisfy $schema" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

CONTRACTS="$REPO_ROOT/infrastructure/terraform/contracts"

metadata_of() { printf '%s' "$1/artifacts/honua.tfplan.metadata.json"; }

digest_of() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_metadata_digest"])' "$(metadata_of "$1")"
}

# =============================================================================
# Positive path
# =============================================================================

CASE="$(new_case happy)"
run_plan "$CASE" --var-file prod.tfvars
expect_success "plan: produces a saved plan and metadata"

META="$(metadata_of "$CASE")"
assert_schema "plan: metadata satisfies terraform-exact-plan.v1" "$META" \
  "$CONTRACTS/terraform-exact-plan.v1.schema.json"
assert_json "plan: binds the exact terraform root" "$META" \
  "doc['source']['terraform_root'] == '$STACK_REL'"
assert_json "plan: binds a 40-char iac revision" "$META" \
  "len(doc['source']['iac_revision']) == 40"
assert_json "plan: binds the provider lock digest" "$META" \
  "len(doc['toolchain']['provider_lock_digest']) == 64"
assert_json "plan: binds the backend config digest" "$META" \
  "len(doc['backend']['backend_config_digest']) == 64"
assert_json "plan: records the S3 native lock primitive" "$META" \
  "doc['backend']['locking']['kind'] == 's3-native-lockfile'"
assert_json "plan: records bucket arn, key and region" "$META" \
  "doc['backend']['bucket_arn'].startswith('arn:aws:s3:::') and doc['backend']['object_key'] and doc['backend']['region'] == 'us-east-1'"
assert_json "plan: records the KMS reference" "$META" \
  "doc['backend']['encryption']['kms_key_reference'].startswith('arn:aws:kms:')"
assert_json "plan: records account and assumed role" "$META" \
  "doc['identity']['account_id'] == '123456789012' and 'assumed-role' in doc['identity']['assumed_role_arn']"
assert_json "plan: records prior state lineage and serial" "$META" \
  "doc['state_before']['serial'] == 12 and doc['state_before']['lineage']"
assert_json "plan: binds the saved plan sha256" "$META" \
  "len(doc['plan']['sha256']) == 64"
assert_json "plan: hashes inputs without recording values" "$META" \
  "len(doc['inputs']['input_digest']) == 64 and all('=' not in ref for ref in doc['inputs']['input_refs'])"
assert_json "plan: is stamped unqualified pre-apply" "$META" \
  "doc['qualification_status'] == 'unqualified' and doc['evidence_scope'] == 'metadata-only-pre-apply'"
assert_json "plan: an offline run can never present as release qualified" "$META" \
  "doc['posture']['release_qualified'] is False"

if grep -q 'never-recorded' "$META"; then
  echo "[FAIL] plan: metadata leaked state contents" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "[PASS] plan: metadata carries no state contents"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

HAPPY_DIGEST="$(digest_of "$CASE")"
[[ -f "$CASE/artifacts/honua.tfplan.metadata.json.digest" ]] &&
  echo "[PASS] plan: writes a sidecar approval digest" && PASS_COUNT=$((PASS_COUNT + 1))

# Dry run passes every gate without mutating.
DRY="$(new_case dryrun)"
cp -a "$CASE/artifacts/." "$DRY/artifacts/"
run_apply "$DRY" --approved-digest "$HAPPY_DIGEST" --allow-unqualified --dry-run
expect_success "apply: --dry-run passes every gate"

# Full apply produces a receipt.
OK="$(new_case apply-ok)"
cp -a "$CASE/artifacts/." "$OK/artifacts/"
FAKE_TF_OUTPUT_DIGEST="c0ffee$(printf '0%.0s' {1..58})" \
  run_apply "$OK" --approved-digest "$HAPPY_DIGEST" --allow-unqualified \
  --receipt-out "$OK/artifacts/receipt.json"
expect_success "apply: consumes the exact saved plan"

assert_schema "receipt: satisfies terraform-exec-receipt.v1" "$OK/artifacts/receipt.json" \
  "$CONTRACTS/terraform-exec-receipt.v1.schema.json"
assert_json "receipt: records exit status and success" "$OK/artifacts/receipt.json" \
  "doc['exit_status'] == 0 and doc['status'] == 'succeeded'"
assert_json "receipt: records resulting state lineage and serial" "$OK/artifacts/receipt.json" \
  "doc['state_after']['serial'] == 13 and doc['state_before']['serial'] == 12"
assert_json "receipt: records the backend step" "$OK/artifacts/receipt.json" \
  "doc['backend_step']['object_key'] and doc['backend_step']['locking']['kind'] == 's3-native-lockfile'"
assert_json "receipt: records the workload identity reference" "$OK/artifacts/receipt.json" \
  "'assumed-role' in doc['workload_identity']['assumed_role_arn']"
assert_json "receipt: records a cleanup/teardown handle" "$OK/artifacts/receipt.json" \
  "doc['cleanup']['teardown_action'] == 'destroy' and doc['cleanup']['saved_plan']"
assert_json "receipt: carries no state contents" "$OK/artifacts/receipt.json" \
  "'never-recorded' not in json.dumps(doc)"

# A destroy plan round-trips too.
DES="$(new_case destroy)"
run_plan "$DES" --action destroy
expect_success "plan: produces a destroy plan"
run_apply "$DES" --allow-unqualified --dry-run
expect_success "apply: accepts a matching destroy plan"

# =============================================================================
# Negative path: plan-time refusals
# =============================================================================

CASE="$(new_case local-state)"
python3 - "$CASE/$STACK_REL/.terraform/terraform.tfstate" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
data["backend"] = {"type": "local", "config": {}}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
run_plan "$CASE"
expect_refusal "plan: refuses local state" "local-state-refused"

CASE="$(new_case no-lock)"
python3 - "$CASE/$STACK_REL/.terraform/terraform.tfstate" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
data["backend"]["config"].pop("use_lockfile", None)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
run_plan "$CASE"
expect_refusal "plan: refuses a backend with no locking primitive" "lock-posture-missing"

CASE="$(new_case old-terraform)"
FAKE_TF_VERSION=1.9.8 run_plan "$CASE"
expect_refusal "plan: refuses S3 native locking on Terraform < 1.10" "lock-primitive-unsupported"

CASE="$(new_case iam-user)"
STS_FIXTURE="$CASE/fixtures/sts-iam-user.json" run_plan "$CASE"
expect_refusal "plan: refuses a long-lived IAM user principal" "long-lived-credential-refused"

CASE="$(new_case dirty-source)"
echo '# uncommitted' >>"$CASE/$STACK_REL/main.tf"
run_plan "$CASE"
expect_refusal "plan: refuses a mutable (uncommitted) IaC source" "mutable-source"

# Distribution tarball: no git metadata. Unpinnable by default, pinnable with an
# explicit release revision, and still digest-bound to the files on disk.
CASE="$(new_case tarball-unpinned)"
rm -rf "$CASE/.git"
run_plan "$CASE"
expect_refusal "plan: refuses an unpinnable tarball source" "mutable-source"

CASE="$(new_case tarball-pinned)"
rm -rf "$CASE/.git"
run_plan "$CASE" --iac-revision "release-2026.1.0"
expect_success "plan: accepts a tarball source pinned to an explicit revision"
assert_json "plan: records the explicit release revision" "$(metadata_of "$CASE")" \
  "doc['source']['iac_revision'] == 'release-2026.1.0' and len(doc['source']['iac_tree_digest']) == 64"
printf '\n# tampered after packaging\n' >>"$CASE/$STACK_REL/main.tf"
run_apply "$CASE" --allow-unqualified
expect_refusal "apply: a tarball source edited after packaging still moves the digest" "source-changed"

CASE="$(new_case no-provider-lock)"
rm -f "$CASE/$STACK_REL/.terraform.lock.hcl"
git -C "$CASE" -c commit.gpgsign=false commit -qam "drop lock"
run_plan "$CASE"
expect_refusal "plan: refuses a root with no provider lock" "provider-lock-missing"

# =============================================================================
# Negative path: apply-time refusals
# =============================================================================

apply_case() {
  # apply_case <name> -- copies the happy-path artifacts into a fresh case dir
  local name="$1"
  local dir
  dir="$(new_case "$name")"
  cp -a "$TMP_DIR/case-happy/artifacts/." "$dir/artifacts/"
  printf '%s' "$dir"
}

CASE="$(apply_case missing-plan)"
rm -f "$CASE/artifacts/honua.tfplan"
run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses a missing saved plan" "saved-plan-missing"

CASE="$(apply_case missing-metadata)"
rm -f "$CASE/artifacts/honua.tfplan.metadata.json"
run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses a plan with no metadata" "plan-metadata-missing"

CASE="$(apply_case tampered-metadata)"
python3 - "$(metadata_of "$CASE")" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    doc = json.load(handle)
doc["identity"]["account_id"] = "999988887777"
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(doc, handle)
PY
run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses metadata edited after signing" "metadata-tampered"

CASE="$(apply_case wrong-approval)"
run_apply "$CASE" --allow-unqualified --approved-digest "$(printf 'a%.0s' {1..64})"
expect_refusal "apply: refuses an approval bound to another plan" "approval-digest-mismatch"

CASE="$(apply_case no-approval)"
set +e
PATH="$FAKE_BIN:$PATH" HONUA_IAC_REQUIRE_APPROVAL=1 HONUA_IAC_OFFLINE=1 \
  HONUA_IAC_STS_FIXTURE="$CASE/fixtures/sts.json" \
  HONUA_IAC_STATE_FIXTURE="$CASE/fixtures/state-before.json" \
  "$CASE/scripts/terraform-exact-apply.sh" --plan "$CASE/artifacts/honua.tfplan" \
  --allow-unqualified >"$CASE/apply.log" 2>&1
LAST_EXIT=$?
set -e
LAST_LOG="$CASE/apply.log"
expect_refusal "apply: refuses a missing approval binding" "approval-binding-missing"

CASE="$(apply_case action-mismatch)"
run_apply "$CASE" --allow-unqualified --action destroy
expect_refusal "apply: refuses to run an apply plan as a destroy" "action-mismatch"

CASE="$(apply_case expired)"
python3 - "$(metadata_of "$CASE")" <<'PY'
import hashlib
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    doc = json.load(handle)
doc["expires_at_utc"] = "2000-01-01T00:00:00Z"
doc.pop("plan_metadata_digest")
canonical = json.dumps(doc, sort_keys=True, separators=(",", ":")).encode("utf-8")
doc["plan_metadata_digest"] = hashlib.sha256(canonical).hexdigest()
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(doc, handle)
PY
run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses an expired plan" "plan-expired"

CASE="$(apply_case tampered-plan)"
printf 'tampered' >"$CASE/artifacts/honua.tfplan"
run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses a saved plan whose bytes changed" "saved-plan-tampered"

CASE="$(apply_case unqualified)"
run_apply "$CASE"
expect_refusal "apply: refuses a non-release-qualified plan by default" "unqualified-plan-refused"

CASE="$(apply_case concurrent)"
mkdir -p "$CASE/artifacts/honua.tfplan.claim"
run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses a concurrent claim on the same plan" "concurrent-claim"

CASE="$(apply_case replay)"
mkdir -p "$CASE/artifacts/honua.tfplan.claim"
echo "2026-01-01T00:00:00Z" >"$CASE/artifacts/honua.tfplan.claim/completed"
run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses a replayed (already consumed) plan" "plan-already-claimed"

CASE="$(apply_case tf-version)"
FAKE_TF_VERSION=1.12.0 run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses a changed Terraform version" "terraform-version-changed"

CASE="$(apply_case provider-lock)"
printf '\n# rotated\n' >>"$CASE/$STACK_REL/.terraform.lock.hcl"
git -C "$CASE" -c commit.gpgsign=false commit -qam "rotate provider lock"
run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses a changed provider lock" "provider-lock-changed"

CASE="$(apply_case source-changed)"
printf '\n# drifted\n' >>"$CASE/$STACK_REL/main.tf"
git -C "$CASE" -c commit.gpgsign=false commit -qam "drift the source"
run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses changed IaC source" "source-changed"

CASE="$(apply_case backend-substituted)"
write_backend_state "$CASE/$STACK_REL" "attacker-owned-bucket"
run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses a substituted backend" "backend-substituted"

CASE="$(apply_case workspace)"
FAKE_TF_WORKSPACE=staging run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses a changed workspace" "workspace-mismatch"

CASE="$(apply_case account)"
STS_FIXTURE="$CASE/fixtures/sts-other-account.json" run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses a different AWS account" "account-mismatch"

CASE="$(apply_case role)"
STS_FIXTURE="$CASE/fixtures/sts-other-role.json" run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses a different execution role" "role-mismatch"

CASE="$(apply_case iam-user-apply)"
STS_FIXTURE="$CASE/fixtures/sts-iam-user.json" run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses a long-lived IAM user at execution time" "long-lived-credential-refused"

CASE="$(apply_case inputs)"
printf 'desired_count = 8\n' >"$CASE/$STACK_REL/runtime.auto.tfvars"
run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses changed inputs" "input-digest-changed"

CASE="$(apply_case state-lineage)"
STATE_FIXTURE="$CASE/fixtures/state-substituted.json" run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses substituted state lineage" "state-lineage-changed"

CASE="$(apply_case state-serial)"
STATE_FIXTURE="$CASE/fixtures/state-drifted.json" run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses drifted state serial" "state-serial-drift"

CASE="$(apply_case local-state-apply)"
python3 - "$CASE/$STACK_REL/.terraform/terraform.tfstate" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
data["backend"] = {"type": "local", "config": {}}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
run_apply "$CASE" --allow-unqualified
expect_refusal "apply: refuses local state at execution time" "local-state-refused"

# =============================================================================
# Retry, concurrency, and recovery
# =============================================================================

# A refusal must leave no stale claim behind, so the operator can fix the cause
# and retry the same approved plan.
CASE="$(apply_case retry)"
FAKE_TF_WORKSPACE=staging run_apply "$CASE" --allow-unqualified
expect_refusal "retry: a refused apply is refused" "workspace-mismatch"
if [[ -d "$CASE/artifacts/honua.tfplan.claim" ]]; then
  echo "[FAIL] retry: a refused apply left a stale claim behind" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "[PASS] retry: a refused apply leaves no stale claim"
  PASS_COUNT=$((PASS_COUNT + 1))
fi
run_apply "$CASE" --allow-unqualified --dry-run
expect_success "retry: the same approved plan is accepted after the cause is fixed"

# Two executors race for the same saved plan. Exactly one may apply.
CASE="$(apply_case race)"
race_apply() {
  local idx="$1"
  local rc=0
  PATH="$FAKE_BIN:$PATH" HONUA_IAC_OFFLINE=1 \
    HONUA_IAC_STS_FIXTURE="$CASE/fixtures/sts.json" \
    HONUA_IAC_STATE_FIXTURE="$CASE/fixtures/state-before.json" \
    HONUA_IAC_STATE_FIXTURE_AFTER="$CASE/fixtures/state-after.json" \
    "$CASE/scripts/terraform-exact-apply.sh" --plan "$CASE/artifacts/honua.tfplan" \
    --allow-unqualified --receipt-out "$CASE/artifacts/receipt-$idx.json" \
    >"$CASE/race-$idx.log" 2>&1 || rc=$?
  echo "$rc" >"$CASE/race-$idx.exit"
}
race_apply 1 &
RACE_PID_1=$!
race_apply 2 &
RACE_PID_2=$!
wait "$RACE_PID_1" 2>/dev/null || true
wait "$RACE_PID_2" 2>/dev/null || true
RACE_WINNERS=0
RACE_REFUSALS=0
for idx in 1 2; do
  if [[ "$(cat "$CASE/race-$idx.exit")" == "0" ]]; then
    RACE_WINNERS=$((RACE_WINNERS + 1))
  elif grep -q 'REFUSED\[concurrent-claim\]\|REFUSED\[plan-already-claimed\]' "$CASE/race-$idx.log"; then
    RACE_REFUSALS=$((RACE_REFUSALS + 1))
  fi
done
if [[ "$RACE_WINNERS" -eq 1 && "$RACE_REFUSALS" -eq 1 ]]; then
  echo "[PASS] concurrency: one plan admitted exactly one apply"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "[FAIL] concurrency: expected 1 winner and 1 refusal, got $RACE_WINNERS/$RACE_REFUSALS" >&2
  cat "$CASE/race-1.log" "$CASE/race-2.log" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# A legacy ambiguous claim cannot prove mutation never started, so time alone
# never makes it replayable.
CASE="$(apply_case disconnect)"
mkdir -p "$CASE/artifacts/honua.tfplan.claim"
echo "2000-01-01T00:00:00Z" >"$CASE/artifacts/honua.tfplan.claim/acquired"
touch -d "2000-01-01" "$CASE/artifacts/honua.tfplan.claim/acquired"
set +e
"$CASE/scripts/terraform-exact-apply.sh" --plan "$CASE/artifacts/honua.tfplan" \
  --claim-status >"$CASE/status.json" 2>&1
LAST_EXIT=$?
set -e
LAST_LOG="$CASE/status.json"
expect_success "recovery: --claim-status reports an interrupted claim"
assert_json "recovery: the interrupted claim reports state=held" "$CASE/status.json" \
  "doc['state'] == 'held' and doc['completed_at_utc'] is None"
run_apply "$CASE" --allow-unqualified --dry-run
expect_refusal "recovery: an interrupted claim is not silently stolen" "concurrent-claim"
run_apply "$CASE" --allow-unqualified --reclaim-after 60 --dry-run
expect_refusal "recovery: an ambiguous legacy claim requires reconciliation" "reconciliation-required"

# Once the Terraform child starts, terminating the wrapper leaves a durable
# reconciliation-required claim. A second claimant cannot overlap or replay it,
# even with a zero-age reclaim window.
CASE="$(apply_case killed-in-flight)"
START_LOG="$CASE/artifacts/terraform-starts"
PATH="$FAKE_BIN:$PATH" HONUA_IAC_OFFLINE=1 \
  HONUA_IAC_STS_FIXTURE="$CASE/fixtures/sts.json" \
  HONUA_IAC_STATE_FIXTURE="$CASE/fixtures/state-before.json" \
  HONUA_IAC_STATE_FIXTURE_AFTER="$CASE/fixtures/state-after.json" \
  HONUA_IAC_EXECUTOR_ID="executor-one" \
  FAKE_TF_APPLY_START_LOG="$START_LOG" FAKE_TF_APPLY_WAIT=1 \
  "$CASE/scripts/terraform-exact-apply.sh" --plan "$CASE/artifacts/honua.tfplan" \
  --allow-unqualified >"$CASE/in-flight.log" 2>&1 &
WRAPPER_PID=$!
for _ in $(seq 1 1500); do [[ -s "$START_LOG" ]] && break; sleep 0.02; done
if [[ ! -s "$START_LOG" ]]; then
  echo "[FAIL] interruption: Terraform child did not start before timeout" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
  kill -TERM "$WRAPPER_PID" 2>/dev/null || true
else
  TERRAFORM_PID="$(tail -1 "$START_LOG")"
  kill -TERM "$WRAPPER_PID" 2>/dev/null || true
  kill -TERM "$TERRAFORM_PID" 2>/dev/null || true
fi
wait "$WRAPPER_PID" 2>/dev/null || true
"$CASE/scripts/terraform-exact-apply.sh" --plan "$CASE/artifacts/honua.tfplan" \
  --claim-status >"$CASE/interrupted-status.json"
assert_json "interruption: mutation-started becomes reconciliation-required" \
  "$CASE/interrupted-status.json" \
  "doc['state'] == 'reconciliation-required' and doc['executor_id'] == 'executor-one'"
run_apply "$CASE" --allow-unqualified --reclaim-after 0
expect_refusal "interruption: retry cannot start a second Terraform mutation" "reconciliation-required"
if [[ "$(wc -l <"$START_LOG")" -eq 1 ]]; then
  echo "[PASS] interruption: exactly one Terraform child started"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "[FAIL] interruption: expected exactly one Terraform child start" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# A receipt committed before completion is also an ambiguous interruption: the
# recovery probe must agree with claim acquisition and require reconciliation.
CASE="$(apply_case receipt-committed)"
mkdir -p "$CASE/artifacts/honua.tfplan.claim"
echo "receipt-committed" >"$CASE/artifacts/honua.tfplan.claim/phase"
echo "executor-receipt" >"$CASE/artifacts/honua.tfplan.claim/executor_id"
"$CASE/scripts/terraform-exact-apply.sh" --plan "$CASE/artifacts/honua.tfplan" \
  --claim-status >"$CASE/receipt-committed-status.json"
assert_json "recovery: receipt-committed requires reconciliation" \
  "$CASE/receipt-committed-status.json" \
  "doc['state'] == 'reconciliation-required' and doc['phase'] == 'receipt-committed'"

# A failed apply still spends the plan: it may have mutated part of the stack, so
# the same bytes must not be reusable.
CASE="$(apply_case failed-apply)"
FAKE_TF_APPLY_EXIT=1 run_apply "$CASE" --allow-unqualified \
  --receipt-out "$CASE/artifacts/receipt.json"
if [[ "$LAST_EXIT" -eq 1 ]]; then
  echo "[PASS] failure: a failed apply propagates terraform's exit status"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "[FAIL] failure: expected exit 1 from a failed apply, got $LAST_EXIT" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
assert_json "failure: the receipt records the failure and the resulting state" \
  "$CASE/artifacts/receipt.json" \
  "doc['status'] == 'failed' and doc['exit_status'] == 1 and doc['state_after']['serial'] == 13"
run_apply "$CASE" --allow-unqualified
expect_refusal "failure: the spent plan cannot be applied again" "plan-already-claimed"

# A COMPLETED claim is never reclaimable -- recovery must not become replay.
CASE="$(apply_case completed-not-reclaimable)"
mkdir -p "$CASE/artifacts/honua.tfplan.claim"
echo "2000-01-01T00:00:00Z" >"$CASE/artifacts/honua.tfplan.claim/acquired"
echo "2000-01-01T00:05:00Z" >"$CASE/artifacts/honua.tfplan.claim/completed"
touch -d "2000-01-01" "$CASE/artifacts/honua.tfplan.claim/acquired"
run_apply "$CASE" --allow-unqualified --reclaim-after 60
expect_refusal "recovery: a completed claim is never reclaimed" "plan-already-claimed"

# --- backend identity script --------------------------------------------------

CASE="$(new_case backend-identity)"
set +e
PATH="$FAKE_BIN:$PATH" HONUA_IAC_OFFLINE=1 \
  HONUA_IAC_STS_FIXTURE="$CASE/fixtures/sts.json" \
  "$CASE/scripts/terraform-backend-identity.sh" --root "$CASE/$STACK_REL" \
  --output "$CASE/artifacts/backend.json" >"$CASE/backend.log" 2>&1
LAST_EXIT=$?
set -e
LAST_LOG="$CASE/backend.log"
expect_success "backend-identity: emits a document for a hardened backend"
assert_schema "backend-identity: satisfies terraform-backend-identity.v1" \
  "$CASE/artifacts/backend.json" "$CONTRACTS/terraform-backend-identity.v1.schema.json"
assert_json "backend-identity: emits account, region, bucket arn, key and digest" \
  "$CASE/artifacts/backend.json" \
  "doc['account']['account_id'] == '123456789012' and doc['location']['region'] == 'us-east-1' and doc['location']['bucket_arn'] and doc['location']['object_key'] and len(doc['backend_config_digest']) == 64"
assert_json "backend-identity: redacts credential-bearing config keys by name" \
  "$CASE/artifacts/backend.json" \
  "'access_key' not in doc['non_secret_config'] and 'secret_key' not in doc['non_secret_config']"
assert_json "backend-identity: reports the lock and KMS posture" \
  "$CASE/artifacts/backend.json" \
  "doc['locking']['kind'] == 's3-native-lockfile' and doc['encryption']['kms_key_reference']"

CASE="$(new_case backend-identity-local)"
python3 - "$CASE/$STACK_REL/.terraform/terraform.tfstate" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
data["backend"] = {"type": "local", "config": {}}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
set +e
PATH="$FAKE_BIN:$PATH" HONUA_IAC_OFFLINE=1 \
  HONUA_IAC_STS_FIXTURE="$CASE/fixtures/sts.json" \
  "$CASE/scripts/terraform-backend-identity.sh" --root "$CASE/$STACK_REL" \
  >"$CASE/backend.log" 2>&1
LAST_EXIT=$?
set -e
LAST_LOG="$CASE/backend.log"
expect_refusal "backend-identity: refuses local state" "local-state-refused"

# =============================================================================

echo
echo "[INFO] exact-plan regression suite: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]] || exit 1
