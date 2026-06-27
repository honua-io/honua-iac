#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
POLICY_GATE_SCRIPT="$SCRIPT_DIR/terraform-policy-gate.sh"
ROOT="${1:-$REPO_ROOT/infrastructure/terraform}"

if [[ ! -x "$POLICY_GATE_SCRIPT" ]]; then
  echo "[ERROR] terraform-policy-gate.sh is not executable: $POLICY_GATE_SCRIPT" >&2
  exit 1
fi

if [[ ! -d "$ROOT" ]]; then
  echo "[ERROR] Terraform root not found: $ROOT" >&2
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

run_gate() {
  local strict="$1"
  local tflint_code="$2"
  local checkov_code="$3"
  local tfsec_code="$4"
  # tfsec is disabled by default; opt it in (5th arg) to exercise its path.
  local tfsec_enabled="${5:-false}"

  GATE_OUTPUT_FILE="$TMP_DIR/policy-gate-${strict}-${tflint_code}-${checkov_code}-${tfsec_code}-${tfsec_enabled}.log"
  set +e
  PATH="$FAKE_BIN:$PATH" \
    FAKE_TFLINT_EXIT_CODE="$tflint_code" \
    FAKE_CHECKOV_EXIT_CODE="$checkov_code" \
    FAKE_TFSEC_EXIT_CODE="$tfsec_code" \
    HONUA_TERRAFORM_ENABLE_TFSEC="$tfsec_enabled" \
    HONUA_TERRAFORM_POLICY_STRICT="$strict" \
    "$POLICY_GATE_SCRIPT" "$ROOT" >"$GATE_OUTPUT_FILE" 2>&1
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

# tfsec is disabled by default, so with it off a non-zero tfsec code must be
# ignored (and the gate must announce that it is disabled).
run_gate "true" 0 0 9 "false"
if [[ "$GATE_EXIT_CODE" -ne 0 ]]; then
  echo "[ERROR] tfsec disabled-by-default should not affect the gate (got $GATE_EXIT_CODE)" >&2
  cat "$GATE_OUTPUT_FILE" >&2
  exit 1
fi
assert_output_contains 'tfsec is disabled by default'

# When tfsec is explicitly enabled, strict mode must propagate its exit code.
run_gate "true" 0 0 6 "true"
if [[ "$GATE_EXIT_CODE" -ne 6 ]]; then
  echo "[ERROR] Strict mode should propagate tfsec exit code 6 when enabled (got $GATE_EXIT_CODE)" >&2
  cat "$GATE_OUTPUT_FILE" >&2
  exit 1
fi
assert_output_contains 'tfsec modules failed with exit code 6'

echo "[INFO] terraform-policy-gate strict/non-strict regression tests passed"
