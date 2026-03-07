#!/usr/bin/env bash

set -euo pipefail

ROOT="${1:-infrastructure/terraform}"
POLICY_STRICT="${HONUA_TERRAFORM_POLICY_STRICT:-false}"

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

  if [[ "${POLICY_STRICT}" == "true" ]]; then
    log_error "${label} failed with exit code ${exit_code}"
    return "${exit_code}"
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

run_tflint() {
  if ! command -v tflint >/dev/null 2>&1; then
    log_warn "tflint is not installed; skipping tflint checks"
    return
  fi

  local roots=(
    "$ROOT/examples/aws"
    "$ROOT/examples/aws-serverless"
    "$ROOT/examples/aws-eks"
    "$ROOT/examples/azure"
    "$ROOT/examples/azure-data"
    "$ROOT/examples/azure-functions"
    "$ROOT/examples/azure-aks"
    "$ROOT/examples/observability"
  )

  local root
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    log_info "tflint: $root"
    run_policy_command "tflint ($root)" run_tflint_in_dir "$root"
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
  # Scope policy gates to repository-managed Terraform only.
  # External modules can introduce findings outside our ownership and should
  # be validated in their upstream source.
  local checkov_image="${HONUA_CHECKOV_IMAGE:-bridgecrew/checkov:3.2.497}"
  local checkov_skip_checks="${HONUA_CHECKOV_SKIP_CHECKS:-CKV_TF_1,CKV_AWS_149,CKV_AWS_191}"
  local checkov_args=(--download-external-modules false --compact)
  if [[ -n "${checkov_skip_checks}" ]]; then
    checkov_args+=(--skip-check "${checkov_skip_checks}")
  fi
  if [[ "${POLICY_STRICT}" != "true" ]]; then
    checkov_args+=(--soft-fail)
  fi

  if command -v checkov >/dev/null 2>&1; then
    log_info "Running checkov"
    run_policy_command "checkov modules" checkov -d "$ROOT/modules" "${checkov_args[@]}"
    run_policy_command "checkov examples" checkov -d "$ROOT/examples" "${checkov_args[@]}"
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    log_info "Running checkov via docker"
    run_policy_command "checkov modules (docker)" docker run --rm -v "$PWD:/workspace" -w /workspace "$checkov_image" \
      checkov -d "$ROOT/modules" "${checkov_args[@]}"
    run_policy_command "checkov examples (docker)" docker run --rm -v "$PWD:/workspace" -w /workspace "$checkov_image" \
      checkov -d "$ROOT/examples" "${checkov_args[@]}"
    return
  fi

  log_warn "checkov unavailable (no binary, no docker); skipping"
}

run_tfsec() {
  local tfsec_image="${HONUA_TFSEC_IMAGE:-aquasec/tfsec:v1.28}"
  local tfsec_args=()
  if [[ "${POLICY_STRICT}" != "true" ]]; then
    tfsec_args+=(--soft-fail)
  fi

  if command -v tfsec >/dev/null 2>&1; then
    log_info "Running tfsec"
    run_policy_command "tfsec modules" tfsec "${tfsec_args[@]}" "$ROOT/modules"
    run_policy_command "tfsec examples" tfsec "${tfsec_args[@]}" "$ROOT/examples"
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    log_info "Running tfsec via docker"
    run_policy_command "tfsec modules (docker)" docker run --rm -v "$PWD:/src" "$tfsec_image" "${tfsec_args[@]}" /src/"$ROOT/modules"
    run_policy_command "tfsec examples (docker)" docker run --rm -v "$PWD:/src" "$tfsec_image" "${tfsec_args[@]}" /src/"$ROOT/examples"
    return
  fi

  log_warn "tfsec unavailable (no binary, no docker); skipping"
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
    "$ROOT/modules/aws-ecs/variables.tf"
    "$ROOT/modules/aws-serverless/variables.tf"
    "$ROOT/modules/aws-eks/variables.tf"
    "$ROOT/modules/azure-aca/variables.tf"
    "$ROOT/modules/azure-data/variables.tf"
    "$ROOT/modules/azure-functions/variables.tf"
    "$ROOT/modules/azure-aks/variables.tf"
    "$ROOT/examples/aws/variables.tf"
    "$ROOT/examples/aws-serverless/variables.tf"
    "$ROOT/examples/aws-eks/variables.tf"
    "$ROOT/examples/azure/variables.tf"
    "$ROOT/examples/azure-data/variables.tf"
    "$ROOT/examples/azure-functions/variables.tf"
    "$ROOT/examples/azure-aks/variables.tf"
  )

  local file
  for file in "${tag_files[@]}"; do
    [[ -f "$file" ]] || continue
    assert_regex_present 'variable "tags"' "$file" "mandatory-tags-variable"
  done

  assert_regex_present 'storage_encrypted[[:space:]]*=[[:space:]]*true' "$ROOT/modules/aws-ecs/main.tf" "aws-ecs-rds-encryption"
  assert_regex_present 'storage_encrypted[[:space:]]*=[[:space:]]*true' "$ROOT/modules/aws-serverless/main.tf" "aws-serverless-rds-encryption"
  assert_regex_present 'transit_encryption_enabled[[:space:]]*=[[:space:]]*true' "$ROOT/modules/aws-ecs/main.tf" "aws-ecs-redis-transit-encryption"
  assert_regex_present 'transit_encryption_enabled[[:space:]]*=[[:space:]]*true' "$ROOT/modules/aws-serverless/main.tf" "aws-serverless-redis-transit-encryption"
  assert_regex_present 'minimum_tls_version[[:space:]]*=[[:space:]]*"1\.2"' "$ROOT/modules/azure-aca/main.tf" "azure-aca-redis-tls12"
  assert_regex_present 'minimum_tls_version[[:space:]]*=[[:space:]]*"1\.2"' "$ROOT/modules/azure-data/main.tf" "azure-data-redis-tls12"
  assert_regex_present 'minimum_tls_version[[:space:]]*=[[:space:]]*"1\.2"' "$ROOT/modules/azure-functions/main.tf" "azure-functions-redis-tls12"

  assert_regex_absent '^[[:space:]]*source[[:space:]]+"\$DATA_CACHE_FILE"' "$ROOT/validation/scripts/aws/run-aws-terraform-integration.sh" "aws-cache-source-execution"
  assert_regex_absent '^[[:space:]]*source[[:space:]]+"\$DATA_CACHE_FILE"' "$ROOT/validation/scripts/azure/run-azure-terraform-integration.sh" "azure-cache-source-execution"
  assert_regex_present 'DATA_CACHE_FORMAT="v2-base64"' "$ROOT/validation/scripts/aws/run-aws-terraform-integration.sh" "aws-cache-format-marker"
  assert_regex_present 'DATA_CACHE_FORMAT="v2-base64"' "$ROOT/validation/scripts/azure/run-azure-terraform-integration.sh" "azure-cache-format-marker"

  assert_regex_absent 'ConnectionStrings__redis[[:space:]]*=[[:space:]]*local\.redis_connection' "$ROOT/modules/aws-serverless/main.tf" "aws-serverless-redis-plaintext-env"
  assert_regex_present 'HONUA_SECRET_REDIS_CONNECTION_ARN' "$ROOT/modules/aws-serverless/main.tf" "aws-serverless-redis-secret-env"

  assert_regex_absent 'ConnectionStrings__redis[[:space:]]*=[[:space:]]*local\.redis_connection' "$ROOT/modules/azure-functions/main.tf" "azure-functions-redis-plaintext-env"
  assert_regex_present 'azurerm_key_vault_secret" "redis_connection"' "$ROOT/modules/azure-functions/main.tf" "azure-functions-redis-secret-resource"
  assert_regex_present 'ConnectionStrings__redis[[:space:]]*=[[:space:]]*"@Microsoft\.KeyVault\(SecretUri=\$\{azurerm_key_vault_secret\.redis_connection\[0\]\.versionless_id\}\)"' "$ROOT/modules/azure-functions/main.tf" "azure-functions-redis-keyvault-reference"

  assert_regex_absent 'kubernetes[[:space:]]*=[[:space:]]*\{' "$ROOT/examples/observability/main.tf" "helm-provider-kubernetes-attribute"
  assert_regex_present '^[[:space:]]*kubernetes[[:space:]]*\{' "$ROOT/examples/observability/main.tf" "helm-provider-kubernetes-block"
}

main() {
  require_dir "$ROOT"
  require_dir "$ROOT/modules"
  require_dir "$ROOT/examples"

  if [[ "${POLICY_STRICT}" == "true" ]]; then
    log_info "Policy scanner strict mode enabled"
  else
    log_warn "Policy scanner strict mode disabled; findings are reported but do not fail the run (set HONUA_TERRAFORM_POLICY_STRICT=true to enforce)"
  fi

  run_tflint
  run_checkov
  run_tfsec
  run_custom_policy_checks

  log_info "Terraform policy gate checks completed successfully"
}

main "$@"
