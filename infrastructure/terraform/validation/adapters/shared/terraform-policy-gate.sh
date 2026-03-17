#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../../../.." && pwd)"
legacy_args=("$@")

args=(
  --repo-root "$repo_root"
  --strict "${HONUA_TERRAFORM_POLICY_STRICT:-false}"
)

if [[ $# -gt 0 && "${1:-}" != --* ]]; then
  args+=(--root "$1")
  shift
fi

if command -v dotnet >/dev/null 2>&1; then
  exec dotnet run --project "$repo_root/infrastructure/terraform/validation/runner/Honua.TerraformValidation.Runner" -- \
    policy-gates \
    "${args[@]}" \
    "$@"
fi

exec bash "$script_dir/../../scripts/shared/terraform-policy-gate.sh" "${legacy_args[@]}"
