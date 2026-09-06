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
      -d "$ROOT/modules" "${checkov_args[@]}"
    run_policy_command "checkov examples (docker)" docker run --rm -v "$PWD:/workspace" -w /workspace "$checkov_image" \
      -d "$ROOT/examples" "${checkov_args[@]}"
    return
  fi

  log_warn "checkov unavailable (no binary, no docker); skipping"
}

run_tfsec() {
  local tfsec_enabled="${HONUA_TERRAFORM_ENABLE_TFSEC:-false}"
  local tfsec_image="${HONUA_TFSEC_IMAGE:-aquasec/tfsec:v1.28}"
  local tfsec_args=()

  if [[ "${tfsec_enabled}" != "true" ]]; then
    log_warn "tfsec is disabled by default because it cannot parse Terraform check blocks in this repository; enable with HONUA_TERRAFORM_ENABLE_TFSEC=true"
    return
  fi

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

assert_required_nullable_variable() {
  local file="$1"
  local variable_name="$2"
  local label="$3"

  if [[ ! -f "$file" ]]; then
    log_error "Policy check failed ($label): file not found: $file"
    exit 1
  fi

  if awk -v target="$variable_name" '
    $0 ~ "^[[:space:]]*variable[[:space:]]+\"" target "\"[[:space:]]*\\{" {
      found = 1
      in_block = 1
      next
    }
    in_block && /^[[:space:]]*default[[:space:]]*=/ { has_default = 1 }
    in_block && /^[[:space:]]*nullable[[:space:]]*=[[:space:]]*true[[:space:]]*$/ { nullable_true = 1 }
    in_block && /^[[:space:]]*}[[:space:]]*$/ {
      closed = 1
      in_block = 0
    }
    END {
      exit !(found && closed && nullable_true && !has_default)
    }
  ' "$file"; then
    return 0
  fi

  log_error "Policy check failed ($label): variable '$variable_name' must be required (no default) and explicitly nullable"
  exit 1
}

# Print the top-level HCL block whose header line starts with $2. Terraform fmt
# guarantees the closing brace of a top-level block sits in column 0, so that is
# the terminator.
extract_hcl_block() {
  local file="$1"
  local header="$2"

  awk -v header="$header" '
    index($0, header) == 1 { inblock = 1 }
    inblock { print }
    inblock && /^\}[ \t]*$/ { inblock = 0 }
  ' "$file"
}

# Print the policy statement whose sid is $2. Statements are two-space indented
# inside an aws_iam_policy_document, so the next statement header terminates the
# current one.
extract_policy_statement() {
  local file="$1"
  local sid="$2"

  awk -v sid="$sid" '
    function flush_chunk() {
      if (chunk ~ ("sid[ \t]*=[ \t]*\"" sid "\"")) printf "%s", chunk
      chunk = ""
    }
    /^  (dynamic "statement"|statement)[ \t]*\{/ { flush_chunk() }
    { chunk = chunk $0 "\n" }
    END { flush_chunk() }
  ' "$file"
}

# A file-wide presence match can be satisfied by an unrelated statement that
# happens to use the same principal, tag key or condition key, so a removed
# invariant would still pass. These assert the pattern inside the one block or
# statement that is supposed to carry it. Comment lines are stripped first so a
# guard cannot be satisfied by prose that merely mentions the key.
assert_scoped_pattern() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  local scope="$4"

  if [[ -z "${scope//[[:space:]]/}" ]]; then
    log_error "Policy check failed ($label): expected pattern not found in $file (guarded block is missing)"
    exit 1
  fi

  # Strip comments so a guard cannot be satisfied by prose that merely mentions
  # the condition key it is supposed to be enforcing.
  if grep -Ev '^[[:space:]]*#' <<<"$scope" | grep -Eq "$pattern"; then
    return 0
  fi

  log_error "Policy check failed ($label): expected pattern not found in $file"
  exit 1
}

assert_regex_present_in_block() {
  local label="$1"
  local file="$2"
  local header="$3"
  local pattern="$4"

  if [[ ! -f "$file" ]]; then
    log_error "Policy check failed ($label): file not found: $file"
    exit 1
  fi

  local scope
  scope="$(extract_hcl_block "$file" "$header")"
  assert_scoped_pattern "$label" "$file" "$pattern" "$scope"
}

assert_regex_present_in_statement() {
  local label="$1"
  local file="$2"
  local sid="$3"
  local pattern="$4"

  if [[ ! -f "$file" ]]; then
    log_error "Policy check failed ($label): file not found: $file"
    exit 1
  fi

  local scope
  scope="$(extract_policy_statement "$file" "$sid")"
  assert_scoped_pattern "$label" "$file" "$pattern" "$scope"
}

assert_single_wildcard_exception() {
  local file="$1"
  local label="$2"
  local sanctioned_action="$3"
  local sanctioned_condition="$4"

  if [[ ! -f "$file" ]]; then
    log_error "Policy check failed ($label): file not found: $file"
    exit 1
  fi

  # Split the document into policy statements and allow at most one statement
  # whose resource list contains "*", and only when that statement is the
  # sanctioned action carrying the sanctioned condition. Any additional
  # wildcard, or a wildcard that migrates onto some other action, fails.
  #
  # Whitespace inside each statement is collapsed before matching: a line
  # oriented regex cannot see `resources = [` with the "*" element on the next
  # line, which is ordinary HCL formatting and would otherwise slip past.
  local findings
  findings="$(awk -v action="$sanctioned_action" -v cond="$sanctioned_condition" '
    function statement_sid(flat,   sid) {
      sid = "<unnamed statement>"
      if (match(flat, /sid[ ]*=[ ]*"[^"]+"/)) {
        sid = substr(flat, RSTART, RLENGTH)
        sub(/sid[ ]*=[ ]*"/, "", sid)
        sub(/"$/, "", sid)
      }
      return sid
    }
    function flush_chunk(   flat, sid) {
      flat = chunk
      gsub(/[ \t\r\n]+/, " ", flat)
      if (flat ~ /resources[ ]*=[ ]*\[[^]]*"\*"/) {
        wildcards++
        sid = statement_sid(flat)
        if (index(flat, action) == 0 || index(flat, cond) == 0) {
          print "  " sid ": Resource \"*\" without " action " and " cond
        } else if (wildcards > 1) {
          print "  " sid ": additional Resource \"*\" grant"
        }
      }
      chunk = ""
    }
    /^  (dynamic "statement"|statement)[ \t]*\{/ { flush_chunk() }
    { chunk = chunk $0 "\n" }
    END { flush_chunk() }
  ' "$file")"

  if [[ -z "$findings" ]]; then
    return 0
  fi

  log_error "Policy check failed ($label): disallowed pattern found"
  printf '%s\n' "$findings"
  exit 1
}

run_custom_policy_checks() {
  log_info "Running custom policy checks"

  assert_regex_absent 'actions[[:space:]]*=[[:space:]]*\[[[:space:]]*"\*"[[:space:]]*\]' "$ROOT" "least-privilege-actions"
  assert_regex_absent 'Action"[[:space:]]*:[[:space:]]*"\*"' "$ROOT" "least-privilege-actions-json"

  # release#282: the Lambda certification packet must preserve its service
  # trust, tagged lifecycle boundary, and the single sanctioned wildcard grant.
  local lambda_cert="$ROOT/examples/aws-cert/lambda-preview-cert.tf"
  # ec2 is allowed in exactly one place: the execution-role boundary statement
  # that lets Lambda manage the ENIs of the VPC-attached certification function
  # (the six AWSLambdaVPCAccessExecutionRole actions, nothing else).
  local eni_stmt
  eni_stmt="$(extract_policy_statement "$lambda_cert" "CertificationVpcEni")"
  if [ -z "$eni_stmt" ]; then
    echo "[ERROR] Policy check failed (lambda-cert-vpc-eni-statement): expected pattern not found" >&2; echo "  CertificationVpcEni statement missing from $lambda_cert" >&2
    exit 1
  fi
  local eni_extra
  eni_extra="$(printf '%s' "$eni_stmt" | grep -oE '"ec2:[A-Za-z]+"' | grep -vE '^"ec2:(CreateNetworkInterface|DescribeNetworkInterfaces|DescribeSubnets|DeleteNetworkInterface|AssignPrivateIpAddresses|UnassignPrivateIpAddresses)"$' || true)"
  if [ -n "$eni_extra" ]; then
    echo "[ERROR] Policy check failed (lambda-cert-vpc-eni-allowlist): disallowed pattern found" >&2; echo "  unexpected ec2 action(s) in CertificationVpcEni: ${eni_extra//$'\n'/ }" >&2
    exit 1
  fi
  local lambda_cert_no_eni
  lambda_cert_no_eni="$(mktemp)"
  awk '
    function flush_chunk() { if (chunk !~ /sid[ \t]*=[ \t]*"CertificationVpcEni"/) printf "%s", chunk; chunk = "" }
    /^  (dynamic "statement"|statement)[ \t]*\{/ { flush_chunk() }
    { chunk = chunk $0 "\n" }
    END { flush_chunk() }
  ' "$lambda_cert" > "$lambda_cert_no_eni"
  assert_regex_absent '"ecr:SetRepositoryPolicy"|"lambda:UntagResource"|"ec2:' "$lambda_cert_no_eni" "lambda-cert-no-extra-capabilities"

  # ecr:GetAuthorizationToken has no resource-level ARN form in AWS, so it is
  # the single sanctioned Resource "*" grant here and must stay region-scoped.
  assert_regex_present_in_statement "lambda-cert-auth-token-region" "$lambda_cert" \
    "EcrAuthorizationTokenGlobal" 'variable[[:space:]]*=[[:space:]]*"aws:RequestedRegion"'
  # The ENI statement's Resource "*" is sanctioned separately above (six ENI
  # actions only); the single-wildcard rule applies to everything else.
  assert_single_wildcard_exception "$lambda_cert_no_eni" "lambda-cert-no-global-resources" \
    'ecr:GetAuthorizationToken' 'aws:RequestedRegion'
  rm -f "$lambda_cert_no_eni"

  # Each guard below is scoped to the block or statement that must carry the
  # invariant. The Lambda service principal and the purpose resource tag each
  # appear twice in this file, so a file-wide match would let a removed trust
  # or lifecycle condition pass on the strength of the unrelated copy.
  assert_regex_present_in_block "lambda-cert-service-trust" "$lambda_cert" \
    'data "aws_iam_policy_document" "lambda_preview_trust"' \
    'identifiers[[:space:]]*=[[:space:]]*\["lambda.amazonaws.com"\]'
  assert_regex_present_in_block "lambda-cert-execution-boundary" "$lambda_cert" \
    'resource "aws_iam_role" "lambda_preview_execution"' \
    'permissions_boundary[[:space:]]*=[[:space:]]*aws_iam_policy.lambda_preview_execution_boundary.arn'
  assert_regex_present_in_block "lambda-cert-immutable-images" "$lambda_cert" \
    'resource "aws_ecr_repository" "lambda_preview"' \
    'image_tag_mutability[[:space:]]*=[[:space:]]*"IMMUTABLE"'
  assert_regex_present_in_statement "lambda-cert-required-run-tag" "$lambda_cert" \
    "CreateTaggedCertificationFunction" 'variable[[:space:]]*=[[:space:]]*"aws:RequestTag/honua-cert-run"'
  assert_regex_present_in_statement "lambda-cert-tagged-lifecycle" "$lambda_cert" \
    "InvokeAndDeleteTaggedCertificationFunction" 'variable[[:space:]]*=[[:space:]]*"aws:ResourceTag/honua-purpose"'
  assert_regex_present_in_statement "lambda-cert-passrole-service" "$lambda_cert" \
    "PassOnlyCertificationExecutionRole" 'variable[[:space:]]*=[[:space:]]*"iam:PassedToService"'
  assert_regex_present_in_statement "lambda-cert-passrole-resource" "$lambda_cert" \
    "PassOnlyCertificationExecutionRole" 'resources[[:space:]]*=[[:space:]]*\[aws_iam_role.lambda_preview_execution.arn\]'
  assert_regex_present_in_statement "lambda-cert-image-pull-source" "$lambda_cert" \
    "LambdaCertificationImagePull" 'variable[[:space:]]*=[[:space:]]*"aws:SourceArn"'

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
  assert_regex_present 'override_special[[:space:]]*=[[:space:]]*"!&#\$\^<>-"' "$ROOT/modules/aws-serverless/main.tf" "aws-serverless-redis-auth-character-set"
  assert_regex_present 'minimum_tls_version[[:space:]]*=[[:space:]]*"1\.2"' "$ROOT/modules/azure-aca/main.tf" "azure-aca-redis-tls12"
  assert_regex_present 'minimum_tls_version[[:space:]]*=[[:space:]]*"1\.2"' "$ROOT/modules/azure-data/main.tf" "azure-data-redis-tls12"
  assert_regex_present 'minimum_tls_version[[:space:]]*=[[:space:]]*"1\.2"' "$ROOT/modules/azure-functions/main.tf" "azure-functions-redis-tls12"

  local connection_key_contract_files=(
    "$ROOT/modules/aws-ecs/variables.tf:connection_encryption_master_key"
    "$ROOT/modules/azure-aca/variables.tf:connection_encryption_master_key"
    "$ROOT/modules/azure-functions/variables.tf:connection_encryption_master_key"
    "$ROOT/examples/aws/variables.tf:honua_connection_encryption_master_key"
    "$ROOT/examples/azure/variables.tf:honua_connection_encryption_master_key"
    "$ROOT/examples/azure-functions/variables.tf:honua_connection_encryption_master_key"
    "$ROOT/examples/registry-pin/variables.tf:honua_connection_encryption_master_key"
  )
  local contract_entry contract_file contract_variable
  for contract_entry in "${connection_key_contract_files[@]}"; do
    contract_file="${contract_entry%:*}"
    contract_variable="${contract_entry##*:}"
    assert_required_nullable_variable "$contract_file" "$contract_variable" "connection-encryption-key-required-input"
  done

  assert_regex_present 'TF_VAR_honua_connection_encryption_master_key="\$HONUA_ADMIN_PASSWORD"' "$ROOT/validation/scripts/aws/run-aws-terraform-integration.sh" "aws-validation-connection-encryption-key"
  assert_regex_present 'TF_VAR_honua_connection_encryption_master_key="\$HONUA_ADMIN_PASSWORD"' "$ROOT/validation/scripts/azure/lib/stacks.sh" "azure-validation-connection-encryption-key"
  assert_regex_present '[[:space:]]-e TF_VAR_honua_connection_encryption_master_key' "$ROOT/validation/scripts/aws/run-aws-terraform-integration.sh" "aws-docker-connection-encryption-key"
  assert_regex_present '[[:space:]]-e TF_VAR_honua_connection_encryption_master_key' "$ROOT/validation/scripts/azure/lib/runtime.sh" "azure-docker-connection-encryption-key"

  assert_regex_present 'multi_replica_enabled[[:space:]]*=[[:space:]]*var\.desired_count > 1 \|\| var\.max_capacity > 1' "$ROOT/modules/aws-ecs/main.tf" "aws-ecs-multinode-scale-detection"
  assert_regex_present 'condition[[:space:]]*=[[:space:]]*!local\.multi_replica_enabled \|\| local\.multi_node_topology_ready' "$ROOT/modules/aws-ecs/main.tf" "aws-ecs-multinode-precondition"
  assert_regex_present 'Deployment__Mode[[:space:]]*=[[:space:]]*var\.deployment_mode' "$ROOT/modules/aws-ecs/main.tf" "aws-ecs-deployment-mode-wiring"
  assert_regex_present 'aws_iam_role_policy" "file_storage_s3"' "$ROOT/modules/aws-ecs/main.tf" "aws-ecs-s3-task-role-policy"

  assert_regex_present 'multi_replica_enabled[[:space:]]*=[[:space:]]*var\.min_replicas > 1 \|\| var\.max_replicas > 1' "$ROOT/modules/azure-aca/main.tf" "azure-aca-multinode-scale-detection"
  assert_regex_present 'condition[[:space:]]*=[[:space:]]*!local\.multi_replica_enabled \|\| local\.multi_node_topology_ready' "$ROOT/modules/azure-aca/main.tf" "azure-aca-multinode-precondition"
  assert_regex_present 'name[[:space:]]*=[[:space:]]*"Deployment__Mode"' "$ROOT/modules/azure-aca/main.tf" "azure-aca-deployment-mode-wiring"
  assert_regex_present 'azurerm_key_vault_secret" "file_storage_azure_blob_connection"' "$ROOT/modules/azure-aca/main.tf" "azure-aca-blob-keyvault-secret"
  assert_regex_present 'name[[:space:]]*=[[:space:]]*"FileStorage__AzureBlob__ConnectionString"' "$ROOT/modules/azure-aca/main.tf" "azure-aca-blob-secret-env"

  assert_regex_absent '^[[:space:]]*source[[:space:]]+"\$DATA_CACHE_FILE"' "$ROOT/validation/scripts/aws/run-aws-terraform-integration.sh" "aws-cache-source-execution"
  assert_regex_absent '^[[:space:]]*source[[:space:]]+"\$DATA_CACHE_FILE"' "$ROOT/validation/scripts/azure/run-azure-terraform-integration.sh" "azure-cache-source-execution"
  assert_regex_present 'DATA_CACHE_FORMAT="v2-base64"' "$ROOT/validation/scripts/aws/run-aws-terraform-integration.sh" "aws-cache-format-marker"
  assert_regex_present 'DATA_CACHE_FORMAT="v2-base64"' "$ROOT/validation/scripts/azure/run-azure-terraform-integration.sh" "azure-cache-format-marker"

  assert_regex_absent 'ConnectionStrings__redis[[:space:]]*=[[:space:]]*local\.redis_connection' "$ROOT/modules/aws-serverless/main.tf" "aws-serverless-redis-plaintext-env"
  assert_regex_absent 'HONUA_RUNTIME_REDIS_CONNECTION[[:space:]]*=[[:space:]]*local\.redis_connection' "$ROOT/modules/aws-serverless/main.tf" "aws-serverless-redis-plaintext-env-source"
  assert_regex_present 'aws_secretsmanager_secret" "redis_connection"' "$ROOT/modules/aws-serverless/main.tf" "aws-serverless-redis-secret-resource"
  assert_regex_present 'ConnectionStrings__redis[[:space:]]*=[[:space:]]*"aws:secretsmanager:\$\{aws_secretsmanager_secret\.redis_connection\[0\]\.arn\}"' "$ROOT/modules/aws-serverless/main.tf" "aws-serverless-redis-secretsmanager-reference"

  assert_regex_absent 'ConnectionStrings__redis[[:space:]]*=[[:space:]]*local\.redis_connection' "$ROOT/modules/azure-functions/main.tf" "azure-functions-redis-plaintext-env"
  assert_regex_present 'azurerm_key_vault_secret" "redis_connection"' "$ROOT/modules/azure-functions/main.tf" "azure-functions-redis-secret-resource"
  assert_regex_present 'ConnectionStrings__redis[[:space:]]*=[[:space:]]*"@Microsoft\.KeyVault\(SecretUri=\$\{azurerm_key_vault_secret\.redis_connection\[0\]\.versionless_id\}\)"' "$ROOT/modules/azure-functions/main.tf" "azure-functions-redis-keyvault-reference"

  assert_regex_absent 'kubernetes[[:space:]]*=[[:space:]]*\{' "$ROOT/examples/observability/main.tf" "helm-provider-kubernetes-attribute"
  assert_regex_present '^[[:space:]]*kubernetes[[:space:]]*\{' "$ROOT/examples/observability/main.tf" "helm-provider-kubernetes-block"

  run_governed_execution_policy_checks
}

# Static contract guards for the governed AWS execution substrate (honua-iac#149).
#
# The remote state bootstrap, the certified execution identity, and the
# explicitly unsupported IAM-user bootstraps each carry properties that a later
# well-meaning edit could quietly remove. These guards fail the build instead.
run_governed_execution_policy_checks() {
  log_info "Running governed execution substrate policy checks"

  local tfstate="$ROOT/bootstrap/aws-tfstate/main.tf"

  # --- backend hardening ---------------------------------------------------
  assert_regex_present 'status[[:space:]]*=[[:space:]]*"Enabled"' "$tfstate" "tfstate-versioning-enabled"
  assert_regex_present 'block_public_acls[[:space:]]*=[[:space:]]*true' "$tfstate" "tfstate-block-public-acls"
  assert_regex_present 'block_public_policy[[:space:]]*=[[:space:]]*true' "$tfstate" "tfstate-block-public-policy"
  assert_regex_present 'ignore_public_acls[[:space:]]*=[[:space:]]*true' "$tfstate" "tfstate-ignore-public-acls"
  assert_regex_present 'restrict_public_buckets[[:space:]]*=[[:space:]]*true' "$tfstate" "tfstate-restrict-public-buckets"
  assert_regex_present 'force_destroy[[:space:]]*=[[:space:]]*false' "$tfstate" "tfstate-force-destroy-disabled"
  assert_regex_present 'apply_server_side_encryption_by_default' "$tfstate" "tfstate-default-encryption"
  assert_regex_present 'aws:SecureTransport' "$tfstate" "tfstate-insecure-transport-denied"
  assert_regex_present 'DenyStateSubstrateAdministration' "$tfstate" "tfstate-protection-tamper-denied"
  assert_regex_present 'prevent_destroy[[:space:]]*=[[:space:]]*true' "$tfstate" "tfstate-prevent-destroy"

  # --- certified execution identity: role boundaries -----------------------
  local exec_identity="$ROOT/bootstrap/aws-exec-identity/main.tf"

  assert_regex_present 'DenyStateSubstrateAccess' "$exec_identity" "exec-identity-state-substrate-denied"
  assert_regex_present 'DenyLongLivedCredentials' "$exec_identity" "exec-identity-long-lived-credentials-denied"
  assert_regex_present 'DenyPassingPrivilegedRoles' "$exec_identity" "exec-identity-privileged-passrole-denied"
  assert_regex_present 'iam:PassedToService' "$exec_identity" "exec-identity-passrole-service-scoped"
  assert_regex_present 'aws:RequestedRegion' "$exec_identity" "exec-identity-region-scoped"

  # The certified identity path must never grow an IAM user or access key.
  assert_regex_absent 'resource[[:space:]]+"aws_iam_user"' "$ROOT/bootstrap/aws-exec-identity" "exec-identity-no-iam-user"
  assert_regex_absent 'resource[[:space:]]+"aws_iam_access_key"' "$ROOT/bootstrap/aws-exec-identity" "exec-identity-no-access-key"
  assert_regex_absent 'resource[[:space:]]+"aws_iam_user"' "$ROOT/bootstrap/aws-terraform-oidc" "backend-identity-no-iam-user"
  assert_regex_absent 'resource[[:space:]]+"aws_iam_access_key"' "$ROOT/bootstrap/aws-terraform-oidc" "backend-identity-no-access-key"

  # --- unsupported local-only bootstraps keep their hard markers -----------
  local unsupported_root
  for unsupported_root in aws-ecs aws-eks aws-serverless; do
    assert_regex_present 'HonuaReleasePosture[[:space:]]*=[[:space:]]*"unsupported-local-only"' \
      "$ROOT/bootstrap/$unsupported_root/main.tf" "unsupported-bootstrap-posture-tag"
    if [[ "$unsupported_root" == "aws-ecs" ]]; then
      # The AWS ECS bootstrap now rejects create_access_key through variable
      # validation, rather than a plan-level check. This is an earlier hard
      # failure for the same unsafe contract and must remain policy-guarded.
      assert_regex_present 'condition[[:space:]]*=[[:space:]]*!var\.create_access_key' \
        "$ROOT/bootstrap/$unsupported_root/variables.tf" "unsupported-bootstrap-input-validation"
    else
      assert_regex_present 'check[[:space:]]+"unsupported_for_release_lane"' \
        "$ROOT/bootstrap/$unsupported_root/main.tf" "unsupported-bootstrap-plan-warning"
    fi
    assert_regex_present 'output[[:space:]]+"supported_for_release"' \
      "$ROOT/bootstrap/$unsupported_root/outputs.tf" "unsupported-bootstrap-output-marker"
  done

  # --- backend examples the operator docs promise --------------------------
  local backend_example_stack
  for backend_example_stack in aws aws-serverless aws-eks aws-data; do
    assert_regex_present 'backend[[:space:]]+"s3"' \
      "$ROOT/examples/$backend_example_stack/backend.tf.example" "backend-example-present"
  done
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
