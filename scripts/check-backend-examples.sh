#!/usr/bin/env bash
# Verify the remote-state backend contract for the release-qualified AWS roots.
#
# honua-iac#149 made remote state with locking a precondition of the AWS
# release/certification lane: `scripts/terraform-exact-plan.sh` and
# `scripts/terraform-exact-apply.sh` refuse local state outright
# (`REFUSED[local-state-refused]`) and refuse a remote backend that names no
# locking primitive (`REFUSED[lock-posture-missing]`). A root that ships no
# `backend.tf.example` therefore cannot be planned through the governed
# wrappers at all -- the operator has nothing to copy, and the refusal arrives
# at plan time in a certification account rather than here.
#
# The docs had already promised these files once when they did not exist. This
# closes that loop statically, with no cloud credentials and no network:
#
#   1. every release-qualified AWS root ships a `backend.tf.example`;
#   2. each one declares a remote `backend "s3"` with `encrypt = true` and
#      exactly one active locking primitive;
#   3. each one carries a placeholder bucket and no credential-bearing key, so
#      an example can never leak an account's state substrate or a static key;
#   4. object keys are exclusive -- two roots or two environments can never
#      share one state object;
#   5. no root declares a backend inside a tracked `.tf` file, because a
#      backend you activate by editing a tracked file is not the copy-and-fill
#      artifact the operator docs describe, and its activated form gets
#      committed;
#   6. no activated `backend.tf` is tracked in git; and
#   7. the list of backend examples in `docs/operator-state.md` matches the
#      files on disk exactly, in both directions.
#
# Usage: ./scripts/check-backend-examples.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
examples_dir="$repo_root/infrastructure/terraform/examples"
state_doc="$repo_root/docs/operator-state.md"

# The AWS roots that the 2026.1 release/certification lane may plan and apply.
# Azure state qualification is deliberately out of scope (honua-iac#149).
roots=(
  aws
  aws-serverless
  aws-eks
  aws-data
  aws-cert
)

# Backend arguments that carry, or point directly at, credential material. The
# certified executor federates through STS; none of these belong in a committed
# example.
credential_keys=(
  access_key
  secret_key
  token
  session_token
  profile
  shared_credentials_file
  shared_credentials_files
)

failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Emit a file with comments removed, so a commented fallback line is never
# mistaken for an active setting.
uncommented() {
  awk '
    { line = $0; sub(/#.*/, "", line); sub(/\/\/.*/, "", line); print line }
  ' "$1"
}

# Print the value assigned to a backend argument, or nothing when it is unset.
backend_argument() {
  local file="$1" key="$2"
  uncommented "$file" |
    awk -v key="$key" '
      $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
        value = $0
        sub(/^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=[[:space:]]*/, "", value)
        gsub(/^"|"[[:space:]]*$/, "", value)
        sub(/[[:space:]]+$/, "", value)
        print value
        exit
      }
    '
}

declare -A key_owner=()

for root in "${roots[@]}"; do
  root_dir="$examples_dir/$root"
  example="$root_dir/backend.tf.example"

  printf '==> %s\n' "infrastructure/terraform/examples/$root"

  if [[ ! -d "$root_dir" ]]; then
    fail "$root is listed as release-qualified but infrastructure/terraform/examples/$root does not exist"
    continue
  fi

  if [[ ! -f "$example" ]]; then
    fail "$root ships no backend.tf.example; the governed wrappers refuse this root with local-state-refused"
    continue
  fi

  # A root must not carry its own backend block: the operator activates state by
  # copying backend.tf.example, never by editing a tracked file. Commented blocks
  # count -- a stale commented backend is documentation that contradicts the
  # substrate, which is exactly what this root shipped before honua-iac#149.
  inline="$(grep -lE '^[[:space:]]*#?[[:space:]]*backend[[:space:]]+"' "$root_dir"/*.tf 2>/dev/null || true)"
  if [[ -n "$inline" ]]; then
    while IFS= read -r found; do
      fail "$root declares a backend in a tracked file (${found#"$repo_root"/}); backends belong in backend.tf.example"
    done <<<"$inline"
  fi

  if ! grep -qE '^[[:space:]]*backend[[:space:]]+"s3"[[:space:]]*\{' <(uncommented "$example"); then
    fail "$root/backend.tf.example does not declare an active backend \"s3\" block"
    continue
  fi

  if [[ "$(backend_argument "$example" encrypt)" != "true" ]]; then
    fail "$root/backend.tf.example does not set encrypt = true"
  fi

  locks=()
  [[ "$(backend_argument "$example" use_lockfile)" == "true" ]] && locks+=("use_lockfile")
  [[ -n "$(backend_argument "$example" dynamodb_table)" ]] && locks+=("dynamodb_table")

  case "${#locks[@]}" in
    0)
      fail "$root/backend.tf.example names no locking primitive; the governed wrappers refuse it with lock-posture-missing"
      ;;
    1)
      printf '    locking: %s\n' "${locks[0]}"
      ;;
    *)
      fail "$root/backend.tf.example activates two locking primitives (${locks[*]}); pick one, keep the other commented as the documented fallback"
      ;;
  esac

  bucket="$(backend_argument "$example" bucket)"
  if [[ "$bucket" != REPLACE_* ]]; then
    fail "$root/backend.tf.example names bucket '$bucket' instead of a REPLACE_ placeholder; a committed example must not point at a real state bucket"
  fi

  for key in "${credential_keys[@]}"; do
    if [[ -n "$(backend_argument "$example" "$key")" ]]; then
      fail "$root/backend.tf.example sets '$key'; the certified executor federates through STS and no credential reference belongs in the example"
    fi
  done

  object_key="$(backend_argument "$example" key)"
  if [[ -z "$object_key" ]]; then
    fail "$root/backend.tf.example sets no object key"
    continue
  fi

  if [[ -n "${key_owner[$object_key]:-}" ]]; then
    fail "$root/backend.tf.example shares object key '$object_key' with ${key_owner[$object_key]}; one state object may serve exactly one stack + environment"
  else
    key_owner[$object_key]="$root"
  fi

  if [[ ! "$object_key" =~ ^honua/[a-z0-9-]+/[a-z0-9-]+/terraform\.tfstate$ ]]; then
    fail "$root/backend.tf.example uses object key '$object_key'; expected honua/<stack>/<environment>/terraform.tfstate (see docs/operator-state.md)"
  else
    printf '    object key: %s\n' "$object_key"
  fi
done

printf '==> committed backend.tf\n'
tracked_backend="$(git -C "$repo_root" ls-files 'infrastructure/terraform/**/backend.tf' || true)"
if [[ -n "$tracked_backend" ]]; then
  while IFS= read -r found; do
    fail "$found is committed; an activated backend names the operator's own bucket and role and must stay local"
  done <<<"$tracked_backend"
else
  printf '    none tracked\n'
fi

printf '==> docs/operator-state.md\n'
if [[ ! -f "$state_doc" ]]; then
  fail "docs/operator-state.md is missing; it is the operator-facing contract for these files"
else
  documented="$(grep -oE 'examples/[a-z0-9-]+/backend\.tf\.example' "$state_doc" | sort -u)"
  on_disk="$(cd "$examples_dir" && ls -d */backend.tf.example 2>/dev/null | sed 's|^|examples/|' | sort -u)"

  undocumented="$(comm -13 <(printf '%s\n' "$documented") <(printf '%s\n' "$on_disk"))"
  if [[ -n "$undocumented" ]]; then
    fail "docs/operator-state.md does not list: $(tr '\n' ' ' <<<"$undocumented")"
  fi

  # The failure honua-iac#149 was opened on: docs promising backend examples
  # that were never shipped.
  phantom="$(comm -23 <(printf '%s\n' "$documented") <(printf '%s\n' "$on_disk"))"
  if [[ -n "$phantom" ]]; then
    fail "docs/operator-state.md claims backend examples that do not exist: $(tr '\n' ' ' <<<"$phantom")"
  fi

  if [[ -z "$undocumented" && -z "$phantom" ]]; then
    printf '    documented set matches disk: %s\n' "$(tr '\n' ' ' <<<"$on_disk")"
  fi
fi

if ((failures > 0)); then
  printf '\n%d backend example check(s) failed.\n' "$failures" >&2
  exit 1
fi

printf '\nAll backend example checks passed.\n'
