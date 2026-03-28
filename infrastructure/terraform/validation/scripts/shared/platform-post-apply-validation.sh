platform_validation_log() {
  local level="$1"
  local message="$2"

  case "$level" in
    info)
      if declare -F log_info >/dev/null 2>&1; then
        log_info "$message"
      else
        echo "[INFO] $message"
      fi
      ;;
    warn)
      if declare -F log_warn >/dev/null 2>&1; then
        log_warn "$message"
      else
        echo "[WARN] $message"
      fi
      ;;
    error)
      if declare -F log_error >/dev/null 2>&1; then
        log_error "$message"
      else
        echo "[ERROR] $message" >&2
      fi
      ;;
  esac
}

declare -Ag HONUA_TERRAFORM_OUTPUT_JSON_CACHE=()
declare -Ag HONUA_TERRAFORM_OUTPUT_SOURCE_LOG=()

terraform_output_runner() {
  if declare -F run_tf >/dev/null 2>&1; then
    run_tf "$@"
    return
  fi

  terraform "$@"
}

invalidate_terraform_output_json_cache() {
  local terraform_root="$1"

  if [[ -n "${HONUA_TERRAFORM_OUTPUT_JSON_CACHE[$terraform_root]:-}" ]]; then
    rm -f "${HONUA_TERRAFORM_OUTPUT_JSON_CACHE[$terraform_root]}"
    unset 'HONUA_TERRAFORM_OUTPUT_JSON_CACHE[$terraform_root]'
  fi
}

load_terraform_output_json() {
  local terraform_root="$1"
  local cached_path="${HONUA_TERRAFORM_OUTPUT_JSON_CACHE[$terraform_root]:-}"

  if [[ -n "$cached_path" && -f "$cached_path" ]]; then
    printf '%s' "$cached_path"
    return 0
  fi

  cached_path="$(mktemp "${TMPDIR:-/tmp}/honua-terraform-output.XXXXXX.json")"

  if ! terraform_output_runner -chdir="$terraform_root" output -json > "$cached_path"; then
    rm -f "$cached_path"
    return 1
  fi

  HONUA_TERRAFORM_OUTPUT_JSON_CACHE["$terraform_root"]="$cached_path"
  printf '%s' "$cached_path"
}

materialize_terraform_output_json_input() {
  local input_value="${1:-}"
  local materialized_path=""

  if [[ -z "$input_value" ]]; then
    return 1
  fi

  if [[ -f "$input_value" ]]; then
    printf '%s' "$input_value"
    return 0
  fi

  if [[ "$input_value" =~ ^[[:space:]]*[\{\[] ]]; then
    materialized_path="$(mktemp "${TMPDIR:-/tmp}/honua-platform-output.XXXXXX.json")"
    printf '%s' "$input_value" > "$materialized_path"
    printf '%s' "$materialized_path"
    return 0
  fi

  return 1
}

log_output_source_once() {
  local json_file="$1"
  local description="$2"
  local source="$3"
  local cache_key="${json_file}:${description}:${source}"

  if [[ -n "${HONUA_TERRAFORM_OUTPUT_SOURCE_LOG[$cache_key]:-}" ]]; then
    return 0
  fi

  HONUA_TERRAFORM_OUTPUT_SOURCE_LOG["$cache_key"]=1

  if [[ "$source" == "contract" ]]; then
    platform_validation_log info "Using stack contract for $description"
  else
    platform_validation_log info "Using legacy Terraform output for $description"
  fi
}

resolve_terraform_output_string() {
  local json_file="$1"
  local description="$2"
  local contract_filter="$3"
  local legacy_filter="$4"
  local value=""

  if [[ ! -f "$json_file" ]] || ! command -v jq >/dev/null 2>&1; then
    return 1
  fi

  if value="$(jq -r "$contract_filter" "$json_file" 2>/dev/null)" && [[ -n "$value" && "$value" != "null" ]]; then
    log_output_source_once "$json_file" "$description" "contract"
    printf '%s' "$value"
    return 0
  fi

  if value="$(jq -r "$legacy_filter" "$json_file" 2>/dev/null)" && [[ -n "$value" && "$value" != "null" ]]; then
    log_output_source_once "$json_file" "$description" "legacy"
    printf '%s' "$value"
    return 0
  fi

  return 1
}

resolve_terraform_output_compact_json() {
  local json_file="$1"
  local description="$2"
  local contract_filter="$3"
  local legacy_filter="$4"
  local value=""

  if [[ ! -f "$json_file" ]] || ! command -v jq >/dev/null 2>&1; then
    return 1
  fi

  if value="$(jq -c "$contract_filter" "$json_file" 2>/dev/null)" && [[ -n "$value" && "$value" != "null" ]]; then
    log_output_source_once "$json_file" "$description" "contract"
    printf '%s' "$value"
    return 0
  fi

  if value="$(jq -c "$legacy_filter" "$json_file" 2>/dev/null)" && [[ -n "$value" && "$value" != "null" ]]; then
    log_output_source_once "$json_file" "$description" "legacy"
    printf '%s' "$value"
    return 0
  fi

  return 1
}

terraform_output_validation_capability() {
  local json_file="$1"
  local capability="$2"
  local value=""

  if [[ ! -f "$json_file" ]] || ! command -v jq >/dev/null 2>&1; then
    return 1
  fi

  if value="$(jq -r --arg capability "$capability" '
      if (.validation_contract.value.platform.capabilities | has($capability)) then
        .validation_contract.value.platform.capabilities[$capability]
      else
        empty
      end
    ' "$json_file" 2>/dev/null)" &&
    [[ -n "$value" && "$value" != "null" ]]; then
    log_output_source_once "$json_file" "validation capability '$capability'" "contract"
    printf '%s' "$value"
    return 0
  fi

  return 1
}

terraform_stack_base_url() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "base URL for $terraform_root" \
    '.validation_contract.value.tests.base_url // .deployment_contract.value.endpoints.public_base_url // empty' \
    '.honua_url.value // empty'
}

terraform_stack_database_host() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "database host for $terraform_root" \
    '.deployment_contract.value.dependencies.database.host // empty' \
    '.db_endpoint.value // .database_fqdn.value // .db_fqdn.value // empty'
}

terraform_stack_database_secret_ref() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "database secret reference for $terraform_root" \
    '.deployment_contract.value.dependencies.database.secret_ref // .operations_contract.value.secrets.db_connection_secret // empty' \
    '.db_connection_secret_arn.value // .db_connection_secret_id.value // empty'
}

terraform_stack_cache_secret_ref() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "cache secret reference for $terraform_root" \
    '.deployment_contract.value.dependencies.cache.secret_ref // .operations_contract.value.secrets.redis_connection_secret // empty' \
    '.redis_connection_secret_arn.value // .redis_connection_secret_id.value // empty'
}

terraform_stack_cache_host() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "cache host for $terraform_root" \
    '.deployment_contract.value.dependencies.cache.host // empty' \
    '.redis_primary_endpoint.value // empty'
}

terraform_stack_cache_enabled() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "cache enabled flag for $terraform_root" \
    '.deployment_contract.value.dependencies.cache.enabled // empty' \
    'if ((.redis_connection_string.value // "") != "" or (.redis_primary_endpoint.value // "") != "") then "true" else "false" end'
}

terraform_stack_secret_store_id() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "secret store id for $terraform_root" \
    '.deployment_contract.value.dependencies.secret_store.id // .operations_contract.value.secrets.secret_store.id // empty' \
    '.key_vault_id.value // empty'
}

terraform_stack_network_id() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "network id for $terraform_root" \
    '.deployment_contract.value.dependencies.network.id // empty' \
    '.vpc_id.value // empty'
}

terraform_stack_network_cidr() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "network cidr for $terraform_root" \
    '.deployment_contract.value.dependencies.network.cidr // empty' \
    '.vpc_cidr.value // empty'
}

terraform_stack_public_subnet_ids_json() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_compact_json \
    "$json_file" \
    "public subnet ids for $terraform_root" \
    '.deployment_contract.value.dependencies.network.public_subnet_ids // empty' \
    '.public_subnet_ids.value // empty'
}

terraform_stack_private_subnet_ids_json() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_compact_json \
    "$json_file" \
    "private subnet ids for $terraform_root" \
    '.deployment_contract.value.dependencies.network.private_subnet_ids // empty' \
    '.private_subnet_ids.value // empty'
}

terraform_stack_resource_group() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "resource group for $terraform_root" \
    '.operations_contract.value.grouping.resource_group // .validation_contract.value.artifacts.resource_group // empty' \
    '.resource_group_name.value // empty'
}

terraform_stack_workload_name() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "workload name for $terraform_root" \
    '.deployment_contract.value.workload.name // empty' \
    '.container_app_name.value // .function_app_name.value // .ecs_service_name.value // .lambda_function_name.value // .cluster_name.value // .prometheus_release.value // empty'
}

terraform_stack_cluster_name() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "cluster name for $terraform_root" \
    '.validation_contract.value.artifacts.cluster_name // .deployment_contract.value.workload.cluster_name // empty' \
    '.ecs_cluster_name.value // empty'
}

terraform_stack_canary_enabled() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "canary enabled flag for $terraform_root" \
    '.deployment_contract.value.rollout.canary_enabled // empty' \
    '.canary_enabled.value // empty'
}

terraform_stack_canary_service_name() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "canary service name for $terraform_root" \
    '.deployment_contract.value.rollout.canary_service_name // empty' \
    '.canary_ecs_service_name.value // empty'
}

terraform_stack_canary_header_name() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "canary verification header name for $terraform_root" \
    '.deployment_contract.value.rollout.canary_verification_header_name // empty' \
    '.canary_verification_header_name.value // empty'
}

terraform_stack_canary_header_value() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "canary verification header value for $terraform_root" \
    '.deployment_contract.value.rollout.canary_verification_header_value // empty' \
    '.canary_verification_header_value.value // empty'
}

terraform_stack_current_revision() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "current deploy revision for $terraform_root" \
    '.deployment_contract.value.rollout.current_revision // empty' \
    '.lambda_alias_function_version.value // .control_plane_current_revision.value // .lambda_function_version.value // empty'
}

terraform_stack_desired_revision() {
  local terraform_root="$1"
  local json_file

  json_file="$(load_terraform_output_json "$terraform_root")" || return 1

  resolve_terraform_output_string \
    "$json_file" \
    "desired deploy revision for $terraform_root" \
    '.deployment_contract.value.rollout.desired_revision // empty' \
    '.lambda_function_version.value // .control_plane_desired_revision.value // .control_plane_current_revision.value // .lambda_alias_function_version.value // empty'
}

resolve_platform_validation_root() {
  local runner_path="$1"
  local runner_dir

  runner_dir="$(cd "$(dirname "$runner_path")" && pwd)"

  if [[ -f "$runner_dir/../Honua.sln" ]]; then
    cd "$runner_dir/.." && pwd
    return 0
  fi

  if git -C "$runner_dir" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$runner_dir" rev-parse --show-toplevel
    return 0
  fi

  return 1
}

render_control_plane_config_from_terraform() {
  local validation_root="$1"
  local terraform_output_json_input="${HONUA_PLATFORM_VALIDATION_TERRAFORM_OUTPUT_JSON:-}"
  local terraform_output_json=""
  local render_script="${HONUA_PLATFORM_VALIDATION_RENDER_CONTROL_PLANE_SCRIPT:-$validation_root/scripts/render-control-plane-config-from-terraform.sh}"
  local rendered_config_path="${HONUA_PLATFORM_VALIDATION_CONTROL_PLANE_CONFIG_OUTPUT:-}"
  local rendered_target_id=""
  local rendered_current_revision=""
  local rendered_desired_revision=""
  local -a render_args

  if [[ -z "$terraform_output_json_input" ]]; then
    return 0
  fi

  if ! terraform_output_json="$(materialize_terraform_output_json_input "$terraform_output_json_input")"; then
    platform_validation_log warn "Skipping control-plane config render because Terraform output JSON input was not a readable file or JSON document"
    return 0
  fi

  if [[ ! -f "$render_script" ]]; then
    platform_validation_log warn "Skipping control-plane config render because the render script was not found: $render_script"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    platform_validation_log warn "Skipping control-plane config render because jq is not available"
    return 0
  fi

  if [[ -z "$rendered_config_path" ]]; then
    rendered_config_path="$(mktemp "${TMPDIR:-/tmp}/honua-control-plane-config.XXXXXX.json")"
  fi

  render_args=(
    --terraform-output-json "$terraform_output_json"
    --output "$rendered_config_path"
  )

  if [[ -n "${HONUA_PLATFORM_VALIDATION_DEPLOY_TARGET_ID:-}" ]]; then
    render_args+=(--target-id "$HONUA_PLATFORM_VALIDATION_DEPLOY_TARGET_ID")
  fi

  if ! bash "$render_script" "${render_args[@]}"; then
    platform_validation_log warn "Skipping control-plane config handoff because rendering failed"
    return 0
  fi

  export HONUA_PLATFORM_VALIDATION_CONTROL_PLANE_CONFIG_OUTPUT="$rendered_config_path"

  if rendered_target_id="$(jq -r '.ControlPlane.DeployTargets[0].TargetId // empty' "$rendered_config_path")" && [[ -n "$rendered_target_id" ]]; then
    export HONUA_CLOUD_TEST_DEPLOY_TARGET_ID="$rendered_target_id"
    platform_validation_log info "Derived deploy target id '$rendered_target_id' from Terraform outputs"
  elif [[ -z "${HONUA_CLOUD_TEST_DEPLOY_TARGET_ID:-}" ]]; then
    rendered_target_id="$(
      resolve_terraform_output_string \
        "$terraform_output_json" \
        "control-plane target id" \
        '.deployment_contract.value.rollout.target_id // empty' \
        '.control_plane_target_id.value // .control_plane_target_name.value // .lambda_function_name.value // .ecs_service_name.value // empty'
    )" || true

    if [[ -n "$rendered_target_id" ]]; then
      export HONUA_CLOUD_TEST_DEPLOY_TARGET_ID="$rendered_target_id"
      platform_validation_log info "Derived deploy target id '$rendered_target_id' from Terraform outputs"
    fi
  fi

  if [[ -z "${HONUA_CLOUD_TEST_DEPLOY_CURRENT_REVISION:-}" ]]; then
    rendered_current_revision="$(
      resolve_terraform_output_string \
        "$terraform_output_json" \
        "current deploy revision" \
        '.deployment_contract.value.rollout.current_revision // empty' \
        '.lambda_alias_function_version.value // .control_plane_current_revision.value // .lambda_function_version.value // empty'
    )" || true

    if [[ -n "$rendered_current_revision" ]]; then
      export HONUA_CLOUD_TEST_DEPLOY_CURRENT_REVISION="$rendered_current_revision"
      platform_validation_log info "Derived current deploy revision '$rendered_current_revision' from Terraform outputs"
    fi
  fi

  if [[ -z "${HONUA_CLOUD_TEST_DEPLOY_DESIRED_REVISION:-}" ]]; then
    rendered_desired_revision="$(
      resolve_terraform_output_string \
        "$terraform_output_json" \
        "desired deploy revision" \
        '.deployment_contract.value.rollout.desired_revision // empty' \
        '.lambda_function_version.value // .control_plane_desired_revision.value // .control_plane_current_revision.value // .lambda_alias_function_version.value // empty'
    )" || true

    if [[ -n "$rendered_desired_revision" ]]; then
      export HONUA_CLOUD_TEST_DEPLOY_DESIRED_REVISION="$rendered_desired_revision"
      platform_validation_log info "Derived desired deploy revision '$rendered_desired_revision' from Terraform outputs"
    fi
  fi

  platform_validation_log info "Rendered control-plane config fragment at $rendered_config_path"
}

run_honua_platform_post_apply_validation() {
  local base_url="$1"
  local default_platform="${2:-}"
  local validation_runner="${HONUA_PLATFORM_VALIDATION_SCRIPT:-}"
  local validation_root_override="${HONUA_PLATFORM_VALIDATION_ROOT:-}"
  local validation_root
  local effective_platform
  local include_scale_tests
  local terraform_output_json_input="${HONUA_PLATFORM_VALIDATION_TERRAFORM_OUTPUT_JSON:-}"
  local terraform_output_json=""
  local deploy_plan_support=""
  local mutation_support=""
  local -a runner_args

  if [[ -z "$validation_runner" ]]; then
    return 0
  fi

  if [[ -z "$base_url" ]]; then
    platform_validation_log error "Platform post-apply validation requires a base URL"
    return 1
  fi

  if [[ ! -f "$validation_runner" ]]; then
    platform_validation_log error "Platform validation runner not found: $validation_runner"
    return 1
  fi

  validation_runner="$(cd "$(dirname "$validation_runner")" && pwd)/$(basename "$validation_runner")"

  if [[ -n "$validation_root_override" ]]; then
    if [[ ! -d "$validation_root_override" ]]; then
      platform_validation_log error "Platform validation root not found: $validation_root_override"
      return 1
    fi

    validation_root="$(cd "$validation_root_override" && pwd)"
  elif ! validation_root="$(resolve_platform_validation_root "$validation_runner")"; then
    platform_validation_log error "Could not determine honua-server repository root from $validation_runner"
    return 1
  fi

  effective_platform="${HONUA_PLATFORM_VALIDATION_PLATFORM:-$default_platform}"
  include_scale_tests="${HONUA_PLATFORM_VALIDATION_INCLUDE_SCALE_TESTS:-false}"
  runner_args=()

  if [[ "$include_scale_tests" == "true" ]]; then
    runner_args+=(--include-scale-tests)
  fi

  platform_validation_log info "Running Honua platform post-apply validation against $base_url"

  if [[ -n "$terraform_output_json_input" ]]; then
    terraform_output_json="$(materialize_terraform_output_json_input "$terraform_output_json_input")" || true
  fi

  (
    set -euo pipefail

    cd "$validation_root"

    export HONUA_CLOUD_TEST_BASE_URL="$base_url"

    if [[ -n "${HONUA_PLATFORM_VALIDATION_ADMIN_API_KEY:-}" ]]; then
      export HONUA_CLOUD_TEST_ADMIN_API_KEY="$HONUA_PLATFORM_VALIDATION_ADMIN_API_KEY"
    elif [[ -n "${HONUA_ADMIN_PASSWORD:-}" ]]; then
      export HONUA_CLOUD_TEST_ADMIN_API_KEY="$HONUA_ADMIN_PASSWORD"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_EXPECTED_ENVIRONMENT:-}" ]]; then
      export HONUA_CLOUD_TEST_EXPECTED_ENVIRONMENT="$HONUA_PLATFORM_VALIDATION_EXPECTED_ENVIRONMENT"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_EXPECTED_DEPLOYMENT_MODE:-}" ]]; then
      export HONUA_CLOUD_TEST_EXPECTED_DEPLOYMENT_MODE="$HONUA_PLATFORM_VALIDATION_EXPECTED_DEPLOYMENT_MODE"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_EXPECT_READY_FOR_COORDINATED_DEPLOY:-}" ]]; then
      export HONUA_CLOUD_TEST_EXPECT_READY_FOR_COORDINATED_DEPLOY="$HONUA_PLATFORM_VALIDATION_EXPECT_READY_FOR_COORDINATED_DEPLOY"
    fi

    if [[ -n "$effective_platform" ]]; then
      export HONUA_CLOUD_TEST_PLATFORM="$effective_platform"
    fi

    render_control_plane_config_from_terraform "$validation_root"

    if [[ -f "$terraform_output_json" ]]; then
      if [[ -z "${HONUA_CLOUD_TEST_EXPECT_DEPLOY_PLAN_SUPPORT:-}" ]]; then
        deploy_plan_support="$(terraform_output_validation_capability "$terraform_output_json" "deploy_plan")" || true
        if [[ -n "$deploy_plan_support" ]]; then
          export HONUA_CLOUD_TEST_EXPECT_DEPLOY_PLAN_SUPPORT="$deploy_plan_support"
          platform_validation_log info "Derived deploy-plan support '$deploy_plan_support' from Terraform validation contract"
        fi
      fi

      if [[ -z "${HONUA_CLOUD_TEST_EXPECT_MUTATION_SUPPORT:-}" ]]; then
        mutation_support="$(terraform_output_validation_capability "$terraform_output_json" "mutation")" || true
        if [[ -n "$mutation_support" ]]; then
          export HONUA_CLOUD_TEST_EXPECT_MUTATION_SUPPORT="$mutation_support"
          platform_validation_log info "Derived mutation support '$mutation_support' from Terraform validation contract"
        fi
      fi
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_DEPLOY_TARGET_ID:-}" ]]; then
      export HONUA_CLOUD_TEST_DEPLOY_TARGET_ID="$HONUA_PLATFORM_VALIDATION_DEPLOY_TARGET_ID"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_DEPLOY_DESIRED_REVISION:-}" ]]; then
      export HONUA_CLOUD_TEST_DEPLOY_DESIRED_REVISION="$HONUA_PLATFORM_VALIDATION_DEPLOY_DESIRED_REVISION"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_DEPLOY_CURRENT_REVISION:-}" ]]; then
      export HONUA_CLOUD_TEST_DEPLOY_CURRENT_REVISION="$HONUA_PLATFORM_VALIDATION_DEPLOY_CURRENT_REVISION"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_EXECUTE_DEPLOY_OPERATION:-}" ]]; then
      export HONUA_CLOUD_TEST_EXECUTE_DEPLOY_OPERATION="$HONUA_PLATFORM_VALIDATION_EXECUTE_DEPLOY_OPERATION"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_VERIFY_DEPLOY_ROLLBACK:-}" ]]; then
      export HONUA_CLOUD_TEST_VERIFY_DEPLOY_ROLLBACK="$HONUA_PLATFORM_VALIDATION_VERIFY_DEPLOY_ROLLBACK"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_DEPLOY_TIMEOUT_SECONDS:-}" ]]; then
      export HONUA_CLOUD_TEST_DEPLOY_TIMEOUT_SECONDS="$HONUA_PLATFORM_VALIDATION_DEPLOY_TIMEOUT_SECONDS"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_IMPORT_TABLE_PREFIX:-}" ]]; then
      export HONUA_CLOUD_TEST_IMPORT_TABLE_PREFIX="$HONUA_PLATFORM_VALIDATION_IMPORT_TABLE_PREFIX"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_IMPORT_TIMEOUT_SECONDS:-}" ]]; then
      export HONUA_CLOUD_TEST_IMPORT_TIMEOUT_SECONDS="$HONUA_PLATFORM_VALIDATION_IMPORT_TIMEOUT_SECONDS"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_PUBLISH_DB_HOST:-}" ]]; then
      export HONUA_CLOUD_TEST_PUBLISH_DB_HOST="$HONUA_PLATFORM_VALIDATION_PUBLISH_DB_HOST"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_PUBLISH_DB_PORT:-}" ]]; then
      export HONUA_CLOUD_TEST_PUBLISH_DB_PORT="$HONUA_PLATFORM_VALIDATION_PUBLISH_DB_PORT"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_PUBLISH_DB_NAME:-}" ]]; then
      export HONUA_CLOUD_TEST_PUBLISH_DB_NAME="$HONUA_PLATFORM_VALIDATION_PUBLISH_DB_NAME"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_PUBLISH_DB_USERNAME:-}" ]]; then
      export HONUA_CLOUD_TEST_PUBLISH_DB_USERNAME="$HONUA_PLATFORM_VALIDATION_PUBLISH_DB_USERNAME"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_PUBLISH_DB_PASSWORD:-}" ]]; then
      export HONUA_CLOUD_TEST_PUBLISH_DB_PASSWORD="$HONUA_PLATFORM_VALIDATION_PUBLISH_DB_PASSWORD"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_PUBLISH_DB_SSL_MODE:-}" ]]; then
      export HONUA_CLOUD_TEST_PUBLISH_DB_SSL_MODE="$HONUA_PLATFORM_VALIDATION_PUBLISH_DB_SSL_MODE"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_PUBLISH_DB_SSL_REQUIRED:-}" ]]; then
      export HONUA_CLOUD_TEST_PUBLISH_DB_SSL_REQUIRED="$HONUA_PLATFORM_VALIDATION_PUBLISH_DB_SSL_REQUIRED"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_SCALE_TEST_BASE_URL:-}" ]]; then
      export HONUA_SCALE_TEST_BASE_URL="$HONUA_PLATFORM_VALIDATION_SCALE_TEST_BASE_URL"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_SCALE_TEST_ADMIN_API_KEY:-}" ]]; then
      export HONUA_SCALE_TEST_ADMIN_API_KEY="$HONUA_PLATFORM_VALIDATION_SCALE_TEST_ADMIN_API_KEY"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_SCALE_TEST_SERVICE_ID:-}" ]]; then
      export HONUA_SCALE_TEST_SERVICE_ID="$HONUA_PLATFORM_VALIDATION_SCALE_TEST_SERVICE_ID"
    fi

    if [[ -n "${HONUA_PLATFORM_VALIDATION_SCALE_TEST_REDIS:-}" ]]; then
      export HONUA_SCALE_TEST_REDIS="$HONUA_PLATFORM_VALIDATION_SCALE_TEST_REDIS"
    fi

    export INCLUDE_SCALE_TESTS="$include_scale_tests"

    bash "$validation_runner" "${runner_args[@]}"
  )
}
