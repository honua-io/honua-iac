#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../../../.." && pwd)"

if command -v dotnet >/dev/null 2>&1; then
  exec dotnet run --project "$repo_root/infrastructure/terraform/validation/runner/Honua.TerraformValidation.Runner" -- \
    k8s-live \
    --repo-root "$repo_root" \
    --deployment-profile "${HONUA_DEPLOYMENT_PROFILE:-ephemeral}" \
    --apply-confirmation "${HONUA_APPLY_CONFIRMATION:-APPROVED}" \
    "$@"
fi

exec bash "$script_dir/../../scripts/k8s/run-k8s-terraform-integration.sh" "$@"
