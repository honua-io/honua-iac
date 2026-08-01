#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
POLICY_GATE_SCRIPT="$SCRIPT_DIR/terraform-policy-gate.sh"
SOURCE_ROOT="${1:-$REPO_ROOT/infrastructure/terraform}"

if [[ ! -x "$POLICY_GATE_SCRIPT" ]]; then
  echo "[ERROR] terraform-policy-gate.sh is not executable: $POLICY_GATE_SCRIPT" >&2
  exit 1
fi

if [[ ! -d "$SOURCE_ROOT" ]]; then
  echo "[ERROR] Terraform root not found: $SOURCE_ROOT" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/fake-bin"
mkdir -p "$FAKE_BIN"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat > "$FAKE_BIN/tflint" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--init" ]]; then
  exit 0
fi
exit "${FAKE_TFLINT_EXIT_CODE:-0}"
EOF

cat > "$FAKE_BIN/checkov" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit "${FAKE_CHECKOV_EXIT_CODE:-0}"
EOF

cat > "$FAKE_BIN/tfsec" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit "${FAKE_TFSEC_EXIT_CODE:-0}"
EOF

chmod +x "$FAKE_BIN/tflint" "$FAKE_BIN/checkov" "$FAKE_BIN/tfsec"

# Build a hermetic copy of the Terraform tree to run the gate against. We exclude
# provider/module caches (.terraform) and Terraform state so the custom policy
# checks see only repository-managed sources. This mirrors how ripgrep skips
# .gitignored paths in CI; without it the grep fallback would descend into
# downloaded modules that legitimately contain wildcard IAM actions and produce
# false positives, and the negative cases below would not be isolated.
FIXTURE_ROOT="$TMP_DIR/fixture"
mkdir -p "$FIXTURE_ROOT"
(
  cd "$SOURCE_ROOT"
  tar \
    --exclude='.terraform' \
    --exclude='.terraform.lock.hcl' \
    --exclude='*.tfstate' \
    --exclude='*.tfstate.*' \
    -cf - .
) | (
  cd "$FIXTURE_ROOT"
  tar -xf -
)

run_gate() {
  local strict="$1"
  local tflint_code="$2"
  local checkov_code="$3"
  local tfsec_code="$4"
  local target_root="${5:-$FIXTURE_ROOT}"

  GATE_OUTPUT_FILE="$TMP_DIR/policy-gate-$(basename "$target_root")-${strict}-${tflint_code}-${checkov_code}-${tfsec_code}.log"
  set +e
  PATH="$FAKE_BIN:$PATH" \
    FAKE_TFLINT_EXIT_CODE="$tflint_code" \
    FAKE_CHECKOV_EXIT_CODE="$checkov_code" \
    FAKE_TFSEC_EXIT_CODE="$tfsec_code" \
    HONUA_TERRAFORM_POLICY_STRICT="$strict" \
    "$POLICY_GATE_SCRIPT" "$target_root" >"$GATE_OUTPUT_FILE" 2>&1
  GATE_EXIT_CODE=$?
  set -e
}

assert_output_contains() {
  local pattern="$1"
  if ! grep -Eq "$pattern" "$GATE_OUTPUT_FILE"; then
    echo "[ERROR] Expected pattern not found: $pattern" >&2
    cat "$GATE_OUTPUT_FILE" >&2
    exit 1
  fi
}

# --- Scanner exit-code plumbing (strict vs non-strict) ---

run_gate "false" 2 0 0
if [[ "$GATE_EXIT_CODE" -ne 0 ]]; then
  echo "[ERROR] Non-strict mode should not fail when tflint fails (exit code: $GATE_EXIT_CODE)" >&2
  cat "$GATE_OUTPUT_FILE" >&2
  exit 1
fi
assert_output_contains 'continuing because strict mode is disabled'

run_gate "true" 0 7 0
if [[ "$GATE_EXIT_CODE" -ne 7 ]]; then
  echo "[ERROR] Strict mode should propagate checkov exit code 7 (got $GATE_EXIT_CODE)" >&2
  cat "$GATE_OUTPUT_FILE" >&2
  exit 1
fi
assert_output_contains 'checkov modules failed with exit code 7'

run_gate "true" 5 0 0
if [[ "$GATE_EXIT_CODE" -ne 5 ]]; then
  echo "[ERROR] Strict mode should propagate tflint exit code 5 (got $GATE_EXIT_CODE)" >&2
  cat "$GATE_OUTPUT_FILE" >&2
  exit 1
fi
assert_output_contains 'tflint \(.+\) failed with exit code 5'

# --- Custom security-guard coverage ---
#
# The strict/non-strict cases above only exercise scanner exit-code propagation.
# They do not prove the bespoke guards in run_custom_policy_checks() actually
# catch a violation. assert_regex_absent passes whenever its pattern matches
# nothing, so a stale or typo'd "absent" guard would silently false-pass. The
# cases below inject each disallowed pattern those guards target and assert the
# gate exits non-zero with the matching label, so a neutered guard regex fails
# the suite instead of going unnoticed.

# Positive control: a clean copy of the tree passes all gates (scanners stubbed
# green). This guards against the negative cases passing for the wrong reason
# (e.g. an unrelated guard already failing on the pristine fixture).
run_gate "true" 0 0 0
if [[ "$GATE_EXIT_CODE" -ne 0 ]]; then
  echo "[ERROR] Clean fixture should pass the policy gate (exit code: $GATE_EXIT_CODE)" >&2
  cat "$GATE_OUTPUT_FILE" >&2
  exit 1
fi
assert_output_contains 'Terraform policy gate checks completed successfully'

assert_violation_detected() {
  local label="$1"
  local target_file="$2"
  local inject_line="$3"

  local fixture="$TMP_DIR/violation-$label"
  rm -rf "$fixture"
  cp -a "$FIXTURE_ROOT" "$fixture"

  local target_path="$fixture/$target_file"
  if [[ ! -f "$target_path" ]]; then
    echo "[ERROR] Negative-test target file not found: $target_path" >&2
    exit 1
  fi
  printf '\n%s\n' "$inject_line" >> "$target_path"

  run_gate "true" 0 0 0 "$fixture"
  if [[ "$GATE_EXIT_CODE" -eq 0 ]]; then
    echo "[ERROR] Policy gate did not fail after injecting '$label' violation into $target_file" >&2
    cat "$GATE_OUTPUT_FILE" >&2
    exit 1
  fi
  assert_output_contains "Policy check failed \\($label\\): disallowed pattern found"
  rm -rf "$fixture"
}

# The injected violation strings are assembled from fragments so this test file
# does not itself contain any literal pattern the assert_regex_absent guards
# match -- the policy gate scans the whole Terraform tree, which includes this
# file, so a raw literal here would make the real gate flag its own test.
Q='"'
STAR='*'
DOLLAR='$'
OPEN_BRACE='{'
RC='redis_connection'

# Least-privilege IAM (HCL list form and embedded JSON policy form).
assert_violation_detected 'least-privilege-actions' \
  'modules/aws-ecs/main.tf' "  actions = [${Q}${STAR}${Q}]"
assert_violation_detected 'least-privilege-actions-json' \
  'modules/aws-ecs/main.tf' "        ${Q}Action${Q}: ${Q}${STAR}${Q}"

# Redis connection strings must not be passed as plaintext runtime env vars.
assert_violation_detected 'aws-serverless-redis-plaintext-env' \
  'modules/aws-serverless/main.tf' "  ConnectionStrings__redis = local.${RC}"
assert_violation_detected 'azure-functions-redis-plaintext-env' \
  'modules/azure-functions/main.tf' "  ConnectionStrings__redis = local.${RC}"

# Generated ElastiCache AUTH tokens must use only AWS-supported punctuation.
REDIS_AUTH_FIXTURE="$TMP_DIR/violation-aws-serverless-redis-auth-character-set"
cp -a "$FIXTURE_ROOT" "$REDIS_AUTH_FIXTURE"
sed -i '/override_special = "!&#$\^<>-"/d' \
  "$REDIS_AUTH_FIXTURE/modules/aws-serverless/main.tf"
run_gate "true" 0 0 0 "$REDIS_AUTH_FIXTURE"
if [[ "$GATE_EXIT_CODE" -eq 0 ]]; then
  echo "[ERROR] Policy gate accepted an unbounded ElastiCache AUTH character set" >&2
  cat "$GATE_OUTPUT_FILE" >&2
  exit 1
fi
assert_output_contains 'Policy check failed \(aws-serverless-redis-auth-character-set\)'
rm -rf "$REDIS_AUTH_FIXTURE"

# Data-cache files must never be sourced/executed by the integration runners.
assert_violation_detected 'aws-cache-source-execution' \
  'validation/scripts/aws/run-aws-terraform-integration.sh' "  source ${Q}${DOLLAR}DATA_CACHE_FILE${Q}"
assert_violation_detected 'azure-cache-source-execution' \
  'validation/scripts/azure/run-azure-terraform-integration.sh' "  source ${Q}${DOLLAR}DATA_CACHE_FILE${Q}"

# Helm provider must declare a kubernetes block, not a kubernetes attribute (=).
assert_violation_detected 'helm-provider-kubernetes-attribute' \
  'examples/observability/main.tf' "  kubernetes = ${OPEN_BRACE}"

# Connection-encryption key migration must fail closed. Adding a default turns
# omission into a silent key replacement on upgrade, so the custom contract
# guard must reject it even when all external scanners report success.
REQUIRED_KEY_FIXTURE="$TMP_DIR/violation-connection-encryption-key-required-input"
cp -a "$FIXTURE_ROOT" "$REQUIRED_KEY_FIXTURE"
sed -i '/variable "connection_encryption_master_key" {/a\  default = null' \
  "$REQUIRED_KEY_FIXTURE/modules/aws-ecs/variables.tf"
run_gate "true" 0 0 0 "$REQUIRED_KEY_FIXTURE"
if [[ "$GATE_EXIT_CODE" -eq 0 ]]; then
  echo "[ERROR] Policy gate accepted a defaulted connection-encryption key input" >&2
  cat "$GATE_OUTPUT_FILE" >&2
  exit 1
fi
assert_output_contains 'Policy check failed \(connection-encryption-key-required-input\)'
rm -rf "$REQUIRED_KEY_FIXTURE"

# Validation runners must supply the same durable key to Terraform. Removing
# either the host export or Docker forwarding must fail the custom gate.
for wiring_case in \
  'aws-validation-connection-encryption-key:export TF_VAR_honua_connection_encryption_master_key' \
  'aws-docker-connection-encryption-key:-e TF_VAR_honua_connection_encryption_master_key'; do
  wiring_label="${wiring_case%%:*}"
  wiring_pattern="${wiring_case#*:}"
  WIRING_FIXTURE="$TMP_DIR/violation-$wiring_label"
  cp -a "$FIXTURE_ROOT" "$WIRING_FIXTURE"
  sed -i "\\|$wiring_pattern|d" \
    "$WIRING_FIXTURE/validation/scripts/aws/run-aws-terraform-integration.sh"
  run_gate "true" 0 0 0 "$WIRING_FIXTURE"
  if [[ "$GATE_EXIT_CODE" -eq 0 ]]; then
    echo "[ERROR] Policy gate accepted missing validation wiring: $wiring_label" >&2
    cat "$GATE_OUTPUT_FILE" >&2
    exit 1
  fi
  assert_output_contains "Policy check failed \\($wiring_label\\): expected pattern not found"
  rm -rf "$WIRING_FIXTURE"
done

echo "[INFO] terraform-policy-gate strict/non-strict regression tests passed"
echo "[INFO] terraform-policy-gate custom security-guard negative tests passed"
