#!/usr/bin/env bash
# Regression test for scripts/check-backend-examples.sh.
#
# The gate decides whether a root may enter the AWS release/certification lane
# at all, so its refusal logic is the thing under test -- a gate that passes
# everything is worse than no gate, because it reads like assurance. Each case
# builds a throwaway repo (its own git repo, its own docs, its own examples),
# runs the real script against it, and asserts on the specific message.
#
# Fully offline: no terraform, no credentials, no network.
#
# Usage: ./infrastructure/terraform/validation/scripts/shared/test-backend-examples.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
gate="$repo_root/scripts/check-backend-examples.sh"

[[ -x "$gate" ]] || {
  printf 'FAIL: %s is missing or not executable\n' "$gate" >&2
  exit 1
}

passed=0
failed=0

pass() {
  printf '  [PASS] %s\n' "$1"
  passed=$((passed + 1))
}

fail() {
  printf '  [FAIL] %s\n' "$1" >&2
  failed=$((failed + 1))
}

# The five roots the gate requires. Listed here deliberately rather than read
# from the gate, so a silent narrowing of its root list fails this test.
roots=(aws aws-serverless aws-eks aws-data aws-cert)
declare -A environments=(
  [aws]=prod
  [aws-serverless]=prod
  [aws-eks]=prod
  [aws-data]=prod
  [aws-cert]=cert
)

# Build a minimal repo the gate accepts, so each case can break exactly one
# thing. Echoes the fixture root.
make_fixture() {
  local dir root root_dir
  dir="$(mktemp -d)"

  mkdir -p "$dir/scripts" "$dir/docs"
  cp "$gate" "$dir/scripts/check-backend-examples.sh"

  {
    printf '### Backend examples that exist\n\n'
    for root in "${roots[@]}"; do
      printf -- '- `examples/%s/backend.tf.example`\n' "$root"
    done
  } >"$dir/docs/operator-state.md"

  for root in "${roots[@]}"; do
    root_dir="$dir/infrastructure/terraform/examples/$root"
    mkdir -p "$root_dir"
    printf 'terraform {\n  required_version = ">= 1.5, < 2.0"\n}\n' >"$root_dir/versions.tf"
    cat >"$root_dir/backend.tf.example" <<EOF
terraform {
  backend "s3" {
    bucket       = "REPLACE_WITH_STATE_BUCKET_NAME"
    key          = "honua/$root/${environments[$root]}/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true

    # dynamodb_table = "REPLACE_WITH_STATE_LOCK_TABLE_NAME"
  }
}
EOF
  done

  git -C "$dir" init --quiet
  git -C "$dir" add -A
  git -C "$dir" -c user.email=t@example.invalid -c user.name=t commit --quiet -m fixture

  printf '%s' "$dir"
}

# --- mutators: each breaks exactly one thing -------------------------------

drop_cert_example() {
  rm "$1/infrastructure/terraform/examples/aws-cert/backend.tf.example"
}

# Deleting the file AND its doc line: the root must still be refused for being
# unplannable, not merely for a documentation mismatch.
drop_aws_example_and_doc() {
  rm "$1/infrastructure/terraform/examples/aws/backend.tf.example"
  sed -i '/examples\/aws\/backend.tf.example/d' "$1/docs/operator-state.md"
}

drop_encryption() {
  sed -i 's/^    encrypt      = true$/    encrypt      = false/' \
    "$1/infrastructure/terraform/examples/aws/backend.tf.example"
}

drop_lock() {
  sed -i '/use_lockfile/d' "$1/infrastructure/terraform/examples/aws/backend.tf.example"
}

double_lock() {
  sed -i 's/^    # dynamodb_table = /    dynamodb_table = /' \
    "$1/infrastructure/terraform/examples/aws/backend.tf.example"
}

real_bucket() {
  sed -i 's/REPLACE_WITH_STATE_BUCKET_NAME/honua-tfstate-123456789012/' \
    "$1/infrastructure/terraform/examples/aws/backend.tf.example"
}

static_credential() {
  sed -i 's|^    region       = "us-east-1"$|    region       = "us-east-1"\n    access_key   = "AKIAEXAMPLE"|' \
    "$1/infrastructure/terraform/examples/aws/backend.tf.example"
}

shared_key() {
  sed -i 's|honua/aws-cert/cert/terraform.tfstate|honua/aws/prod/terraform.tfstate|' \
    "$1/infrastructure/terraform/examples/aws-cert/backend.tf.example"
}

odd_key() {
  sed -i 's|honua/aws-cert/cert/terraform.tfstate|cert/aws-cert/terraform.tfstate|' \
    "$1/infrastructure/terraform/examples/aws-cert/backend.tf.example"
}

# The exact shape aws-cert shipped before honua-iac#149: a commented backend in
# a tracked file, activated by editing the file rather than copying it.
inline_backend() {
  cat >>"$1/infrastructure/terraform/examples/aws-cert/versions.tf" <<'HCL'

terraform {
  # backend "s3" {
  #   bucket = "honua-tfstate-account"
  # }
}
HCL
}

committed_backend() {
  cp "$1/infrastructure/terraform/examples/aws/backend.tf.example" \
    "$1/infrastructure/terraform/examples/aws/backend.tf"
  git -C "$1" add -A -f
  git -C "$1" -c user.email=t@example.invalid -c user.name=t commit --quiet -m activated
}

# The failure honua-iac#149 was opened on.
phantom_doc() {
  printf -- '- `examples/aws-imaginary/backend.tf.example`\n' >>"$1/docs/operator-state.md"
}

undocumented_example() {
  sed -i '/examples\/aws-cert\/backend.tf.example/d' "$1/docs/operator-state.md"
}

# expect_refusal <label> <expected-substring> <mutator>
expect_refusal() {
  local label="$1" expected="$2" mutate="$3"
  local dir output status
  dir="$(make_fixture)"
  "$mutate" "$dir"

  set +e
  output="$("$dir/scripts/check-backend-examples.sh" 2>&1)"
  status=$?
  set -e

  if ((status == 0)); then
    fail "$label: gate accepted it"
  elif [[ "$output" != *"$expected"* ]]; then
    fail "$label: refused for the wrong reason (wanted '$expected')"
    printf '%s\n' "$output" | sed 's/^/         /' >&2
  else
    pass "$label -> $expected"
  fi

  rm -rf "$dir"
}

# --- cases -----------------------------------------------------------------

printf '== the intended shape passes ==\n'
fixture="$(make_fixture)"
if "$fixture/scripts/check-backend-examples.sh" >/dev/null 2>&1; then
  pass "a correctly wired set of roots passes"
else
  fail "a correctly wired set of roots was refused"
  "$fixture/scripts/check-backend-examples.sh" 2>&1 | sed 's/^/         /' >&2
fi
rm -rf "$fixture"

printf '== refusals ==\n'

expect_refusal "the certification root ships no backend example" \
  "ships no backend.tf.example" drop_cert_example
expect_refusal "the ECS root ships no backend example" \
  "ships no backend.tf.example" drop_aws_example_and_doc
expect_refusal "unencrypted state" \
  "does not set encrypt = true" drop_encryption
expect_refusal "no locking primitive" \
  "names no locking primitive" drop_lock
expect_refusal "two active locking primitives" \
  "activates two locking primitives" double_lock
expect_refusal "a real bucket name committed" \
  "instead of a REPLACE_ placeholder" real_bucket
expect_refusal "a static credential in the example" \
  "federates through STS" static_credential
expect_refusal "two roots sharing one state object" \
  "shares object key" shared_key
expect_refusal "an off-convention object key" \
  "expected honua/<stack>/<environment>" odd_key
expect_refusal "a commented backend in a tracked file" \
  "declares a backend in a tracked file" inline_backend
expect_refusal "an activated backend committed" \
  "must stay local" committed_backend
expect_refusal "docs promising a file that does not exist" \
  "claims backend examples that do not exist" phantom_doc
expect_refusal "a shipped example the docs never mention" \
  "does not list" undocumented_example

printf '\n'
if ((failed > 0)); then
  printf '[FAIL] backend example gate: %d passed, %d failed\n' "$passed" "$failed" >&2
  exit 1
fi

printf '[OK] backend example gate: %d checks passed\n' "$passed"
