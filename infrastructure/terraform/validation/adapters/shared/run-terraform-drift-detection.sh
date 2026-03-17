#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../../../.." && pwd)"
legacy_args=("$@")

if command -v dotnet >/dev/null 2>&1; then
  exec dotnet run --project "$repo_root/infrastructure/terraform/validation/runner/Honua.TerraformValidation.Runner" -- \
    drift \
    --repo-root "$repo_root" \
    "$@"
fi

exec bash "$script_dir/../../scripts/shared/run-terraform-drift-detection.sh" "${legacy_args[@]}"
