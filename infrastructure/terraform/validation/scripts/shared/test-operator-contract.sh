#!/usr/bin/env bash
#
# Contract test for honua.operator-contract/v1.
#
# Runs the validator over the checked-in fixture corpus and asserts that each
# positive fixture passes and each negative fixture fails with the specific
# finding it exists to provoke. A negative fixture that fails for the wrong
# reason is treated as a failure: "it errored" is not evidence that the rule
# under test works.
#
# When a `terraform` binary is available it also proves that Terraform's
# jsonencode() reproduces the canonical bytes the corpus was hashed with, which
# is the only thing that makes the producer's digest checkable by a consumer.
#
# Usage: test-operator-contract.sh [repo-root]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${1:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"

VALIDATOR="$SCRIPT_DIR/validate-operator-contract.mjs"
FIXTURE_DIR="$REPO_ROOT/infrastructure/terraform/contracts/fixtures"
SCHEMA="$REPO_ROOT/infrastructure/terraform/contracts/operator-contract.v1.schema.json"
EXAMPLES_DIR="$REPO_ROOT/infrastructure/terraform/examples"
AWS_ROOT="$EXAMPLES_DIR/aws"

# Every root that ships a contract producer. Listed explicitly so a new
# producer cannot appear without a reviewer deciding which guards apply to it;
# the "producer roster" check below fails if the tree and this list disagree.
CONTRACT_ROOTS=(
  "aws"
  "aws-cert"
)

FAILURES=0
CHECKS=0

log() { printf '%s\n' "$*"; }
pass() { CHECKS=$((CHECKS + 1)); printf '  [PASS] %s\n' "$*"; }
fail() {
  CHECKS=$((CHECKS + 1))
  FAILURES=$((FAILURES + 1))
  printf '  [FAIL] %s\n' "$*" >&2
}

for required in "$VALIDATOR" "$SCHEMA" "$FIXTURE_DIR"; do
  if [[ ! -e "$required" ]]; then
    log "[ERROR] missing required path: $required" >&2
    exit 1
  fi
done

if ! command -v node >/dev/null 2>&1; then
  log "[ERROR] node is required to run the operator-contract validator" >&2
  exit 1
fi

validate() {
  node "$VALIDATOR" --schema "$SCHEMA" "$@"
}

# ---------------------------------------------------------------------------
log "== positive fixtures =="

if validate --expect-valid --quiet "$FIXTURE_DIR/valid-aws-ecs-small.json"; then
  pass "valid-aws-ecs-small.json validates"
else
  validate "$FIXTURE_DIR/valid-aws-ecs-small.json" || true
  fail "valid-aws-ecs-small.json should validate"
fi

if validate --expect-valid --require-qualified --quiet "$FIXTURE_DIR/valid-aws-ecs-small.json"; then
  pass "valid-aws-ecs-small.json satisfies the certified (qualified) posture"
else
  fail "valid-aws-ecs-small.json should satisfy --require-qualified"
fi

# The unqualified projection is schema-valid on purpose: a development plan is
# a legitimate contract shape. It is the certified posture that must reject it.
if validate --expect-valid --quiet "$FIXTURE_DIR/valid-aws-ecs-small-unqualified.json"; then
  pass "valid-aws-ecs-small-unqualified.json is schema-valid"
else
  validate "$FIXTURE_DIR/valid-aws-ecs-small-unqualified.json" || true
  fail "valid-aws-ecs-small-unqualified.json should be schema-valid"
fi

if validate --expect-code E_UNQUALIFIED --require-qualified --quiet \
  "$FIXTURE_DIR/valid-aws-ecs-small-unqualified.json"; then
  pass "an unqualified contract is rejected by a certified consumer"
else
  fail "an unqualified contract must be rejected by --require-qualified"
fi

# examples/aws-cert is a different runtime, not a second copy of the ECS root:
# a Lambda alias behind an HTTP API Gateway, with no cluster, no canary, and an
# extensions block. Keeping it in the positive corpus is what stops the rules
# below from silently becoming ECS-only.
if validate --expect-valid --quiet "$FIXTURE_DIR/valid-aws-cert-lambda.json"; then
  pass "valid-aws-cert-lambda.json validates"
else
  validate "$FIXTURE_DIR/valid-aws-cert-lambda.json" || true
  fail "valid-aws-cert-lambda.json should validate"
fi

if validate --expect-valid --require-qualified --quiet "$FIXTURE_DIR/valid-aws-cert-lambda.json"; then
  pass "valid-aws-cert-lambda.json satisfies the certified (qualified) posture"
else
  fail "valid-aws-cert-lambda.json should satisfy --require-qualified"
fi

# ---------------------------------------------------------------------------
log "== negative fixtures =="

# fixture:expected finding code
NEGATIVE_CASES=(
  "invalid-missing-required-field.json:E_MISSING_FIELD"
  "invalid-unknown-schema-version.json:E_UNKNOWN_VERSION"
  "invalid-mutable-image-tag.json:E_MUTABLE_PIN"
  "invalid-secret-value-leak.json:E_SECRET_VALUE"
  "invalid-contract-digest-mismatch.json:E_DIGEST_MISMATCH"
  "invalid-account-mismatch.json:E_ACCOUNT_MISMATCH"
  "invalid-endpoint-mismatch.json:E_ENDPOINT_MISMATCH"
  "invalid-identity-mismatch.json:E_IDENTITY_MISMATCH"
  "invalid-secret-ref-mismatch.json:E_SECRET_REF_MISMATCH"
)

for case in "${NEGATIVE_CASES[@]}"; do
  fixture="${case%%:*}"
  code="${case##*:}"
  path="$FIXTURE_DIR/$fixture"

  if [[ ! -f "$path" ]]; then
    fail "$fixture is missing from the fixture corpus"
    continue
  fi

  if validate --quiet "$path"; then
    fail "$fixture validated successfully but must be rejected ($code)"
    continue
  fi

  if validate --expect-code "$code" --quiet "$path"; then
    pass "$fixture is rejected with $code"
  else
    validate "$path" || true
    fail "$fixture was rejected, but not with $code"
  fi
done

# Every invalid-* fixture must be covered by a case above; an uncovered fixture
# is a rule nobody is asserting.
for path in "$FIXTURE_DIR"/invalid-*.json; do
  fixture="$(basename "$path")"
  covered=false
  for case in "${NEGATIVE_CASES[@]}"; do
    [[ "${case%%:*}" == "$fixture" ]] && covered=true && break
  done
  if [[ "$covered" == true ]]; then
    continue
  fi
  fail "$fixture has no expected-finding case in this test"
done

# ---------------------------------------------------------------------------
log "== canonicalization agreement =="

DIGEST_INPUT="$FIXTURE_DIR/canonical-digest-input.json"
DIGEST_EXPECTED="$FIXTURE_DIR/canonical-digest-expected.json"

if ! command -v terraform >/dev/null 2>&1; then
  log "  [SKIP] terraform not on PATH; skipping the jsonencode() agreement check"
elif [[ ! -f "$DIGEST_INPUT" || ! -f "$DIGEST_EXPECTED" ]]; then
  fail "canonical digest fixtures are missing"
else
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  cat > "$TMP_DIR/main.tf" <<'EOF'
variable "input_path" {
  type = string
}

output "digest" {
  value = sha256(jsonencode(jsondecode(file(var.input_path))))
}
EOF

  if terraform -chdir="$TMP_DIR" init -backend=false -input=false -no-color >/dev/null 2>&1 &&
    terraform -chdir="$TMP_DIR" apply -auto-approve -no-color \
      -var "input_path=$DIGEST_INPUT" >/dev/null 2>&1; then
    tf_digest="$(terraform -chdir="$TMP_DIR" output -raw digest)"
    js_digest="$(node -e '
      const { readFileSync } = require("node:fs");
      const doc = JSON.parse(readFileSync(process.argv[1], "utf8"));
      process.stdout.write(doc.contract_digest);
    ' "$DIGEST_EXPECTED")"

    if [[ "$tf_digest" == "$js_digest" ]]; then
      pass "terraform jsonencode() reproduces the canonical bytes ($tf_digest)"
    else
      fail "canonical bytes disagree: terraform=$tf_digest corpus=$js_digest"
    fi
  else
    fail "could not evaluate the terraform-side canonicalization check"
  fi
fi

# ---------------------------------------------------------------------------
log "== legacy scalar deprecation guard =="

# Certified automation must not be able to grow a new dependency on an
# unmarked scalar. Every output in the AWS root outside the contract files has
# to carry the non-authoritative marker in its description.
#
# Deliberately scoped to examples/aws. Its scalars (honua_url, the ECS
# cluster/service names) were superseded by the contract and survive only for
# compatibility. examples/aws-cert's scalars are a different thing: the GP and
# custom-code substrate ARNs are the runtime contract the honua-server cert
# fixture reads directly, and the operator contract does not supersede them, so
# marking them "non-authoritative legacy" would be false. They are reported
# additively under the contract's extensions block instead.
LEGACY_OUTPUTS="$AWS_ROOT/outputs.tf"
if [[ ! -f "$LEGACY_OUTPUTS" ]]; then
  fail "expected legacy scalar outputs at $LEGACY_OUTPUTS"
else
  unmarked=0
  while IFS= read -r name; do
    block="$(awk -v target="output \"$name\" {" '
      index($0, target) == 1 { inside = 1 }
      inside { print }
      inside && $0 == "}" { inside = 0 }
    ' "$LEGACY_OUTPUTS")"
    if ! grep -q 'Non-authoritative legacy scalar' <<<"$block"; then
      fail "output \"$name\" in outputs.tf is missing the non-authoritative marker"
      unmarked=$((unmarked + 1))
    fi
  done < <(grep -oP '^output "\K[^"]+' "$LEGACY_OUTPUTS")

  if [[ "$unmarked" -eq 0 ]]; then
    pass "every legacy scalar output in examples/aws is marked non-authoritative"
  fi
fi

# ---------------------------------------------------------------------------
log "== contract producer guards =="

# The roster check: a root that grows a contract producer has to be added to
# CONTRACT_ROOTS, which is what subjects it to the guards below. Without this,
# a new producer would be governed by nothing.
discovered=()
while IFS= read -r producer; do
  discovered+=("$(basename "$(dirname "$producer")")")
done < <(find "$EXAMPLES_DIR" -mindepth 2 -maxdepth 2 -name operator-contract.tf | sort)

expected="$(printf '%s\n' "${CONTRACT_ROOTS[@]}" | sort)"
actual="$(printf '%s\n' "${discovered[@]+"${discovered[@]}"}" | sort)"
if [[ "$expected" == "$actual" ]]; then
  pass "the contract-producer roster matches the roots on disk (${CONTRACT_ROOTS[*]})"
else
  fail "contract producers on disk [$(tr '\n' ' ' <<<"$actual")] do not match CONTRACT_ROOTS [$(tr '\n' ' ' <<<"$expected")]"
fi

# No contract producer may project a raw credential variable. This applies to
# every producer, not just the ECS one: the secretless rule is the whole point
# of the contract, and a second root is exactly where it would erode first.
for root in "${CONTRACT_ROOTS[@]}"; do
  producer="$EXAMPLES_DIR/$root/operator-contract.tf"
  if [[ ! -f "$producer" ]]; then
    fail "examples/$root is listed in CONTRACT_ROOTS but ships no operator-contract.tf"
    continue
  fi
  if grep -nE 'var\.(honua_admin_password|db_password|honua_connection_encryption_master_key|connection_encryption_master_key|redis_connection_string|existing_db_connection_string|canary_header_value|pro_license_content)' \
    "$producer" >/dev/null 2>&1; then
    fail "examples/$root/operator-contract.tf references a raw credential variable"
  else
    pass "examples/$root/operator-contract.tf references no raw credential variable"
  fi
done

# ---------------------------------------------------------------------------
log ""
if [[ "$FAILURES" -eq 0 ]]; then
  log "[OK] operator-contract v1: $CHECKS checks passed"
  exit 0
fi

log "[ERROR] operator-contract v1: $FAILURES of $CHECKS checks failed" >&2
exit 1
