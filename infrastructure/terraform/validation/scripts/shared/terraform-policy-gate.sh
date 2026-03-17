#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
ROOT="${1:-$REPO_ROOT/infrastructure/terraform}"
POLICY_STRICT="${HONUA_TERRAFORM_POLICY_STRICT:-false}"
RUNNER_PROJECT="${HONUA_TERRAFORM_VALIDATION_RUNNER_PROJECT:-$REPO_ROOT/infrastructure/terraform/validation/runner/Honua.Terraform.ValidationRunner/Honua.Terraform.ValidationRunner.csproj}"
declare -a POLICY_ROOTS=()

log_info() {
  echo "[INFO] $1"
}

log_warn() {
  echo "[WARN] $1"
}

log_error() {
  echo "[ERROR] $1" >&2
}

run_policy_command() {
  local label="$1"
  shift

  local exit_code
  if "$@"; then
    return 0
  else
    exit_code=$?
  fi

  if [[ "$POLICY_STRICT" == "true" ]]; then
    log_error "${label} failed with exit code ${exit_code}"
    return "$exit_code"
  fi

  log_warn "${label} failed with exit code ${exit_code}; continuing because strict mode is disabled"
  return 0
}

require_dir() {
  if [[ ! -d "$1" ]]; then
    log_error "Directory not found: $1"
    exit 1
  fi
}

load_policy_roots() {
  if [[ "${#POLICY_ROOTS[@]}" -gt 0 ]]; then
    return
  fi

  if ! command -v dotnet >/dev/null 2>&1; then
    log_error "dotnet is required to load the Terraform validation catalog"
    exit 1
  fi

  if [[ ! -f "$RUNNER_PROJECT" ]]; then
    log_error "Terraform validation runner project not found: $RUNNER_PROJECT"
    exit 1
  fi

  local raw_root
  local relative_root
  while IFS= read -r raw_root; do
    [[ -z "$raw_root" ]] && continue
    if [[ "$raw_root" = /* ]]; then
      relative_root="${raw_root#$REPO_ROOT/}"
    else
      relative_root="$raw_root"
    fi
    POLICY_ROOTS+=("$relative_root")
  done < <(dotnet run --project "$RUNNER_PROJECT" -- roots policy --format lines)

  if [[ "${#POLICY_ROOTS[@]}" -eq 0 ]]; then
    log_error "Terraform validation catalog returned no policy roots"
    exit 1
  fi
}

run_tflint() {
  if ! command -v tflint >/dev/null 2>&1; then
    log_warn "tflint is not installed; skipping tflint checks"
    return
  fi

  load_policy_roots

  local root
  for root in "${POLICY_ROOTS[@]}"; do
    local local_root="$REPO_ROOT/$root"
    [[ -d "$local_root" ]] || continue
    log_info "tflint: $root"
    run_policy_command "tflint ($root)" run_tflint_in_dir "$local_root"
  done
}

run_tflint_in_dir() {
  local root="$1"
  (
    cd "$root"
    tflint --init >/dev/null
    tflint
  )
}

run_checkov() {
  local checkov_image="${HONUA_CHECKOV_IMAGE:-bridgecrew/checkov:3.2.497}"
  local checkov_skip_checks="${HONUA_CHECKOV_SKIP_CHECKS:-CKV_TF_1,CKV_AWS_149,CKV_AWS_191}"
  local checkov_args=(--download-external-modules false --compact)
  if [[ -n "$checkov_skip_checks" ]]; then
    checkov_args+=(--skip-check "$checkov_skip_checks")
  fi
  if [[ "$POLICY_STRICT" != "true" ]]; then
    checkov_args+=(--soft-fail)
  fi

  load_policy_roots

  local root
  if command -v checkov >/dev/null 2>&1; then
    log_info "Running checkov"
    for root in "${POLICY_ROOTS[@]}"; do
      local local_root="$REPO_ROOT/$root"
      [[ -d "$local_root" ]] || continue
      run_policy_command "checkov ($root)" checkov -d "$local_root" "${checkov_args[@]}"
    done
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    log_info "Running checkov via docker"
    for root in "${POLICY_ROOTS[@]}"; do
      local local_root="$REPO_ROOT/$root"
      [[ -d "$local_root" ]] || continue
      run_policy_command "checkov ($root) (docker)" docker run --rm -v "$REPO_ROOT:/workspace" -w /workspace "$checkov_image" \
        -d "$root" "${checkov_args[@]}"
    done
    return
  fi

  log_warn "checkov unavailable (no binary, no docker); skipping"
}

run_trivy_config() {
  local trivy_image="${HONUA_TRIVY_IMAGE:-aquasec/trivy:0.63.0}"
  local trivy_severity="${HONUA_TRIVY_SEVERITY:-HIGH,CRITICAL}"
  local trivy_timeout="${HONUA_TRIVY_TIMEOUT:-15m}"
  local trivy_args=(
    config
    --exit-code 1
    --severity "$trivy_severity"
    --timeout "$trivy_timeout"
    --tf-exclude-downloaded-modules
    --skip-dirs ".terraform"
    --skip-dirs "**/.terraform"
  )

  load_policy_roots

  local root
  if command -v trivy >/dev/null 2>&1; then
    log_info "Running trivy config"
    for root in "${POLICY_ROOTS[@]}"; do
      local local_root="$REPO_ROOT/$root"
      [[ -d "$local_root" ]] || continue
      run_policy_command "trivy config ($root)" trivy "${trivy_args[@]}" "$local_root"
    done
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    log_info "Running trivy config via docker"
    for root in "${POLICY_ROOTS[@]}"; do
      local local_root="$REPO_ROOT/$root"
      [[ -d "$local_root" ]] || continue
      run_policy_command "trivy config ($root) (docker)" docker run --rm -v "$REPO_ROOT:/work" "$trivy_image" "${trivy_args[@]}" "/work/$root"
    done
    return
  fi

  log_warn "trivy unavailable (no binary, no docker); skipping"
}

assert_regex_absent() {
  local pattern="$1"
  local scope="$2"
  local label="$3"

  if command -v rg >/dev/null 2>&1; then
    rg -n "$pattern" "$scope" -S >/tmp/policy-match.txt 2>&1 || true
  else
    grep -REn "$pattern" "$scope" >/tmp/policy-match.txt 2>&1 || true
  fi

  if [[ -s /tmp/policy-match.txt ]]; then
    log_error "Policy check failed ($label): disallowed pattern found"
    cat /tmp/policy-match.txt
    rm -f /tmp/policy-match.txt
    exit 1
  fi
  rm -f /tmp/policy-match.txt
}

assert_regex_present() {
  local pattern="$1"
  local file="$2"
  local label="$3"

  if command -v rg >/dev/null 2>&1; then
    if rg -q "$pattern" "$file" -S; then
      return 0
    fi
  else
    if grep -Eq "$pattern" "$file"; then
      return 0
    fi
  fi

  if [[ ! -f "$file" ]]; then
    log_error "Policy check failed ($label): file not found: $file"
    exit 1
  fi

  log_error "Policy check failed ($label): expected pattern not found in $file"
  exit 1
}

run_custom_policy_checks() {
  log_info "Running custom policy checks"

  assert_regex_absent 'actions[[:space:]]*=[[:space:]]*\[[[:space:]]*"\*"[[:space:]]*\]' "$ROOT" "least-privilege-actions"
  assert_regex_absent 'Action"[[:space:]]*:[[:space:]]*"\*"' "$ROOT" "least-privilege-actions-json"

  local tag_files=(
    "$ROOT/platforms/aws-ecs/variables.tf"
    "$ROOT/platforms/aws-serverless/variables.tf"
    "$ROOT/platforms/aws-eks/variables.tf"
    "$ROOT/platforms/azure-aca/variables.tf"
    "$ROOT/platforms/azure-functions/variables.tf"
    "$ROOT/platforms/azure-aks/variables.tf"
    "$ROOT/components/data/aws-postgres-redis/variables.tf"
    "$ROOT/components/data/azure-postgres-redis/variables.tf"
    "$ROOT/stacks/customer/aws/variables.tf"
    "$ROOT/stacks/customer/aws-data/variables.tf"
    "$ROOT/stacks/customer/aws-eks/variables.tf"
    "$ROOT/stacks/customer/aws-serverless/variables.tf"
    "$ROOT/stacks/customer/azure/variables.tf"
    "$ROOT/stacks/customer/azure-data/variables.tf"
    "$ROOT/stacks/customer/azure-aks/variables.tf"
    "$ROOT/stacks/customer/azure-functions/variables.tf"
  )

  local file
  for file in "${tag_files[@]}"; do
    [[ -f "$file" ]] || continue
    assert_regex_present 'variable "tags"' "$file" "mandatory-tags-variable"
  done

  assert_regex_present 'storage_encrypted[[:space:]]*=[[:space:]]*true' "$ROOT/platforms/aws-ecs/main.tf" "aws-ecs-rds-encryption"
  assert_regex_present 'storage_encrypted[[:space:]]*=[[:space:]]*true' "$ROOT/platforms/aws-serverless/main.tf" "aws-serverless-rds-encryption"
  assert_regex_present 'transit_encryption_enabled[[:space:]]*=[[:space:]]*true' "$ROOT/platforms/aws-ecs/main.tf" "aws-ecs-redis-transit-encryption"
  assert_regex_present 'transit_encryption_enabled[[:space:]]*=[[:space:]]*true' "$ROOT/platforms/aws-serverless/main.tf" "aws-serverless-redis-transit-encryption"
  assert_regex_present 'minimum_tls_version[[:space:]]*=[[:space:]]*"1\.2"' "$ROOT/platforms/azure-aca/main.tf" "azure-aca-redis-tls12"
  assert_regex_present 'minimum_tls_version[[:space:]]*=[[:space:]]*"1\.2"' "$ROOT/components/data/azure-postgres-redis/main.tf" "azure-data-redis-tls12"
  assert_regex_present 'minimum_tls_version[[:space:]]*=[[:space:]]*"1\.2"' "$ROOT/platforms/azure-functions/main.tf" "azure-functions-redis-tls12"

  assert_regex_absent '^[[:space:]]*source[[:space:]]+"\$DATA_CACHE_FILE"' "$ROOT/validation/scripts/aws/run-aws-terraform-integration.sh" "aws-cache-source-execution"
  assert_regex_absent '^[[:space:]]*source[[:space:]]+"\$DATA_CACHE_FILE"' "$ROOT/validation/scripts/azure/run-azure-terraform-integration.sh" "azure-cache-source-execution"
  assert_regex_present 'DATA_CACHE_FORMAT="v2-base64"' "$ROOT/validation/scripts/aws/run-aws-terraform-integration.sh" "aws-cache-format-marker"
  assert_regex_present 'DATA_CACHE_FORMAT="v2-base64"' "$ROOT/validation/scripts/azure/run-azure-terraform-integration.sh" "azure-cache-format-marker"

  assert_regex_absent 'ConnectionStrings__redis[[:space:]]*=[[:space:]]*local\.redis_connection' "$ROOT/platforms/aws-serverless/main.tf" "aws-serverless-redis-plaintext-env"
  assert_regex_present 'ConnectionStrings__redis[[:space:]]*=[[:space:]]*"env:HONUA_RUNTIME_REDIS_CONNECTION"' "$ROOT/platforms/aws-serverless/main.tf" "aws-serverless-redis-env-ref"
  assert_regex_present 'HONUA_RUNTIME_REDIS_CONNECTION[[:space:]]*=[[:space:]]*local\.redis_connection' "$ROOT/platforms/aws-serverless/main.tf" "aws-serverless-redis-env-source"

  assert_regex_absent 'ConnectionStrings__redis[[:space:]]*=[[:space:]]*local\.redis_connection' "$ROOT/platforms/azure-functions/main.tf" "azure-functions-redis-plaintext-env"
  assert_regex_present 'azurerm_key_vault_secret" "redis_connection"' "$ROOT/platforms/azure-functions/main.tf" "azure-functions-redis-secret-resource"
  assert_regex_present 'ConnectionStrings__redis[[:space:]]*=[[:space:]]*"@Microsoft\.KeyVault\(SecretUri=\$\{azurerm_key_vault_secret\.redis_connection\[0\]\.versionless_id\}\)"' "$ROOT/platforms/azure-functions/main.tf" "azure-functions-redis-keyvault-reference"

  assert_regex_absent 'kubernetes[[:space:]]*=[[:space:]]*\{' "$ROOT/stacks/customer/observability/main.tf" "helm-provider-kubernetes-attribute"
  assert_regex_present '^[[:space:]]*kubernetes[[:space:]]*\{' "$ROOT/stacks/customer/observability/main.tf" "helm-provider-kubernetes-block"
}

main() {
  require_dir "$ROOT"
  require_dir "$ROOT/platforms"
  require_dir "$ROOT/components"
  require_dir "$ROOT/stacks/customer"
  require_dir "$ROOT/examples"

  if [[ "$POLICY_STRICT" == "true" ]]; then
    log_info "Policy scanner strict mode enabled"
  else
    log_warn "Policy scanner strict mode disabled; findings are reported but do not fail the run (set HONUA_TERRAFORM_POLICY_STRICT=true to enforce)"
  fi

  run_tflint
  run_checkov
  run_trivy_config
  run_custom_policy_checks

  log_info "Terraform policy gate checks completed successfully"
}

main "$@"
