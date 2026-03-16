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

platform_validation_contract_default() {
  local platform="${1:-}"
  local capability="${2:-}"

  case "${platform}:${capability}" in
    azure-functions:deploy-plan)
      printf 'true\n'
      ;;
    azure-functions:mutation)
      printf 'false\n'
      ;;
    azure-container-apps:deploy-plan|azure-container-apps:mutation)
      printf 'false\n'
      ;;
    kubernetes:deploy-plan)
      printf 'false\n'
      ;;
  esac
}

platform_validation_contract_value() {
  local platform="${1:-}"
  local capability="${2:-}"
  local explicit_value="${3:-}"
  local default_value=""

  if [[ -n "$explicit_value" ]]; then
    printf '%s\n' "$explicit_value"
    return 0
  fi

  default_value="$(platform_validation_contract_default "$platform" "$capability")"
  if [[ -n "$default_value" ]]; then
    printf '%s\n' "$default_value"
  fi
}

export_platform_validation_contract() {
  local platform="${1:-}"
  local deploy_plan_support=""
  local mutation_support=""
  local contract_deploy_plan_support=""
  local contract_mutation_support=""

  if [[ -z "${HONUA_PLATFORM_VALIDATION_EXPECT_DEPLOY_PLAN_SUPPORT:-}" ]]; then
    contract_deploy_plan_support="$(platform_validation_contract_capability_from_terraform "deploy-plan")"
  fi

  if [[ -z "${HONUA_PLATFORM_VALIDATION_EXPECT_MUTATION_SUPPORT:-}" ]]; then
    contract_mutation_support="$(platform_validation_contract_capability_from_terraform "mutation")"
  fi

  deploy_plan_support="$(
    platform_validation_contract_value \
      "$platform" \
      "deploy-plan" \
      "${HONUA_PLATFORM_VALIDATION_EXPECT_DEPLOY_PLAN_SUPPORT:-$contract_deploy_plan_support}"
  )"
  mutation_support="$(
    platform_validation_contract_value \
      "$platform" \
      "mutation" \
      "${HONUA_PLATFORM_VALIDATION_EXPECT_MUTATION_SUPPORT:-$contract_mutation_support}"
  )"

  if [[ -n "$deploy_plan_support" ]]; then
    export HONUA_CLOUD_TEST_EXPECT_DEPLOY_PLAN_SUPPORT="$deploy_plan_support"
  fi

  if [[ -n "$mutation_support" ]]; then
    export HONUA_CLOUD_TEST_EXPECT_MUTATION_SUPPORT="$mutation_support"
  fi
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

platform_validation_resolve_tf_output() {
  local terraform_output_json="${1:-}"
  local key="${2:-}"

  if [[ -z "$terraform_output_json" || -z "$key" || ! -f "$terraform_output_json" ]]; then
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  jq -r --arg key "$key" '
    if has($key) and .[$key].value != null then
      .[$key].value
    else
      empty
    end
  ' "$terraform_output_json"
}

platform_validation_export_env_from_tf_candidates() {
  local env_name="$1"
  local terraform_output_json="$2"
  local value=""
  shift 2

  if [[ -n "${!env_name:-}" || -z "$terraform_output_json" || ! -f "$terraform_output_json" ]]; then
    return 0
  fi

  for key in "$@"; do
    value="$(platform_validation_resolve_tf_output "$terraform_output_json" "$key")"
    if [[ -n "$value" ]]; then
      export "$env_name=$value"
      return 0
    fi
  done
}

platform_validation_contract_capability_from_terraform() {
  local capability="${1:-}"
  local terraform_output_json="${HONUA_PLATFORM_VALIDATION_TERRAFORM_OUTPUT_JSON:-}"
  local query=""

  if [[ -z "$terraform_output_json" || ! -f "$terraform_output_json" ]]; then
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  case "$capability" in
    deploy-plan)
      query='.validation_contract.value.platform.capabilities.deploy_plan // empty'
      ;;
    mutation)
      query='.validation_contract.value.platform.capabilities.mutation // empty'
      ;;
    *)
      return 0
      ;;
  esac

  jq -r "$query | if . == true or . == false then tostring else empty end" "$terraform_output_json"
}

normalize_platform_validation_terraform_output_json() {
  local terraform_output_json="${1:-}"
  local normalized_output_json=""

  if [[ -z "$terraform_output_json" || ! -f "$terraform_output_json" ]]; then
    printf '%s\n' "$terraform_output_json"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$terraform_output_json"
    return 0
  fi

  if ! jq -e '
    .deployment_contract.value? != null or
    .validation_contract.value? != null or
    .operations_contract.value? != null
  ' "$terraform_output_json" >/dev/null 2>&1; then
    printf '%s\n' "$terraform_output_json"
    return 0
  fi

  normalized_output_json="$(mktemp "${TMPDIR:-/tmp}/honua-platform-validation-outputs.XXXXXX.json")"

  if ! jq '
    def tf_type($value):
      if ($value | type) == "boolean" then "bool"
      elif ($value | type) == "number" then "number"
      elif ($value | type) == "string" then "string"
      elif ($value | type) == "array" then "list"
      elif ($value | type) == "object" then "object"
      else "string"
      end;
    def tf_output($value):
      {
        sensitive: false,
        type: tf_type($value),
        value: $value
      };
    def output_entry($key; $value):
      if $value == null or $value == "" then
        {}
      else
        { ($key): tf_output($value) }
      end;
    . as $root
    | ($root.deployment_contract.value // {}) as $deployment
    | ($root.validation_contract.value // {}) as $validation
    | ($root.operations_contract.value // {}) as $operations
    | ($deployment.stack.platform // $validation.platform.name // "") as $platform
    | ($deployment.workload.kind // "") as $target_kind
    | $root
      + output_entry("base_url"; $deployment.endpoints.public_base_url // $validation.tests.base_url // null)
      + output_entry("public_base_url"; $deployment.endpoints.public_base_url // $validation.tests.base_url // null)
      + output_entry("environment"; $deployment.stack.environment // null)
      + output_entry("platform"; $platform)
      + output_entry("deployment_mode"; $validation.tests.expected_deployment_mode // null)
      + output_entry("ready_for_coordinated_deploy"; $validation.tests.expect_ready_for_coordinated_deploy // null)
      + output_entry("control_plane_target_kind"; $target_kind)
      + output_entry("control_plane_backend_name"; $deployment.rollout.backend_name // null)
      + output_entry("control_plane_target_id"; $deployment.rollout.target_id // null)
      + output_entry("control_plane_target_name"; $deployment.rollout.target_name // $deployment.workload.name // null)
      + output_entry("control_plane_target_resource_id"; $deployment.rollout.target_resource_id // $deployment.workload.resource_id // null)
      + output_entry("control_plane_target_resource_group"; $deployment.rollout.target_resource_group // $deployment.workload.resource_group // $operations.grouping.resource_group // null)
      + output_entry("control_plane_telemetry_policy"; $operations.observability.telemetry_policy // null)
      + output_entry("control_plane_telemetry_prometheus_job"; $deployment.rollout.telemetry_prometheus_job // $operations.observability.prometheus_job // null)
      + output_entry("control_plane_telemetry_prometheus_canary_job"; $deployment.rollout.telemetry_prometheus_canary_job // $operations.observability.prometheus_canary_job // null)
      + output_entry("control_plane_current_revision"; $deployment.rollout.current_revision // null)
      + output_entry("control_plane_desired_revision"; $deployment.rollout.desired_revision // null)
      + output_entry("control_plane_current_image"; $deployment.rollout.current_image // null)
      + output_entry("control_plane_desired_image"; $deployment.rollout.desired_image // null)
      + output_entry("canary_verification_header_name"; $validation.tests.extra_header_name // $operations.observability.canary_verification_name // null)
      + output_entry("canary_verification_header_value"; $validation.tests.extra_header_value // $operations.observability.canary_verification_value // null)
      + output_entry("control_plane_slot_name"; if $target_kind == "AzureFunctions" then $deployment.rollout.slot_name // null else null end)
      + output_entry("function_app_slot_name"; if $target_kind == "AzureFunctions" then $deployment.rollout.slot_name // null else null end)
      + output_entry("resource_group_name"; if $platform == "azure-functions" then $deployment.workload.resource_group // $operations.grouping.resource_group // null else null end)
      + output_entry("function_app_name"; if $target_kind == "AzureFunctions" then $deployment.workload.name // null else null end)
      + output_entry("function_app_id"; if $target_kind == "AzureFunctions" then $deployment.workload.resource_id // null else null end)
      + output_entry("container_app_name"; if $target_kind == "AzureContainerApps" then $deployment.workload.name // null else null end)
      + output_entry("container_app_id"; if $target_kind == "AzureContainerApps" then $deployment.workload.resource_id // null else null end)
      + output_entry("container_app_environment_id"; if $target_kind == "AzureContainerApps" then $deployment.workload.environment_id // null else null end)
      + output_entry("aws_region"; if $platform == "aws-lambda" then $deployment.stack.region // $operations.grouping.region // null else null end)
      + output_entry("lambda_function_name"; if $target_kind == "AwsLambda" then $deployment.workload.name // null else null end)
      + output_entry("lambda_alias_name"; if $target_kind == "AwsLambda" then $deployment.rollout.alias_name // null else null end)
      + output_entry("lambda_alias_arn"; if $target_kind == "AwsLambda" then $deployment.rollout.alias_arn // null else null end)
      + output_entry("lambda_alias_invoke_arn"; if $target_kind == "AwsLambda" then $deployment.rollout.alias_invoke_arn // null else null end)
      + output_entry("lambda_alias_function_version"; if $target_kind == "AwsLambda" then $deployment.rollout.current_revision // null else null end)
      + output_entry("lambda_function_version"; if $target_kind == "AwsLambda" then $deployment.rollout.desired_revision // null else null end)
      + output_entry("ecs_cluster_name"; if $target_kind == "AwsEcs" then $deployment.workload.cluster_name // null else null end)
      + output_entry("ecs_service_name"; if $target_kind == "AwsEcs" then $deployment.workload.name // null else null end)
      + output_entry("canary_enabled"; if $target_kind == "AwsEcs" then $deployment.rollout.canary_enabled // null else null end)
      + output_entry("canary_ecs_service_name"; if $target_kind == "AwsEcs" then $deployment.workload.canary_name // null else null end)
  ' "$terraform_output_json" > "$normalized_output_json"; then
    rm -f "$normalized_output_json"
    printf '%s\n' "$terraform_output_json"
    return 0
  fi

  platform_validation_log info "Normalized Terraform outputs for contract-aware post-apply validation: $normalized_output_json" >&2
  printf '%s\n' "$normalized_output_json"
}

export_platform_validation_env_from_terraform_output() {
  local terraform_output_json="${HONUA_PLATFORM_VALIDATION_TERRAFORM_OUTPUT_JSON:-}"

  if [[ -z "$terraform_output_json" || ! -f "$terraform_output_json" ]]; then
    return 0
  fi

  platform_validation_export_env_from_tf_candidates HONUA_CLOUD_TEST_BASE_URL "$terraform_output_json" base_url public_base_url service_url
  platform_validation_export_env_from_tf_candidates HONUA_CLOUD_TEST_ADMIN_API_KEY "$terraform_output_json" admin_api_key
  platform_validation_export_env_from_tf_candidates HONUA_CLOUD_TEST_EXPECTED_ENVIRONMENT "$terraform_output_json" environment
  platform_validation_export_env_from_tf_candidates HONUA_CLOUD_TEST_EXPECTED_DEPLOYMENT_MODE "$terraform_output_json" deployment_mode
  platform_validation_export_env_from_tf_candidates HONUA_CLOUD_TEST_EXPECT_READY_FOR_COORDINATED_DEPLOY "$terraform_output_json" ready_for_coordinated_deploy
  platform_validation_export_env_from_tf_candidates HONUA_CLOUD_TEST_PLATFORM "$terraform_output_json" platform
  platform_validation_export_env_from_tf_candidates HONUA_CLOUD_TEST_DEPLOY_TARGET_ID "$terraform_output_json" control_plane_target_id
  platform_validation_export_env_from_tf_candidates HONUA_CLOUD_TEST_DEPLOY_DESIRED_REVISION "$terraform_output_json" control_plane_desired_revision lambda_function_version control_plane_current_revision
  platform_validation_export_env_from_tf_candidates HONUA_CLOUD_TEST_DEPLOY_CURRENT_REVISION "$terraform_output_json" lambda_alias_function_version control_plane_current_revision lambda_function_version
  platform_validation_export_env_from_tf_candidates HONUA_CLOUD_TEST_EXTRA_HEADER_NAME "$terraform_output_json" canary_verification_header_name
  platform_validation_export_env_from_tf_candidates HONUA_CLOUD_TEST_EXTRA_HEADER_VALUE "$terraform_output_json" canary_verification_header_value
  platform_validation_export_env_from_tf_candidates HONUA_SCALE_TEST_BASE_URL "$terraform_output_json" scale_test_base_url
  platform_validation_export_env_from_tf_candidates HONUA_SCALE_TEST_ADMIN_API_KEY "$terraform_output_json" scale_test_admin_api_key
  platform_validation_export_env_from_tf_candidates HONUA_SCALE_TEST_SERVICE_ID "$terraform_output_json" scale_test_service_id
  platform_validation_export_env_from_tf_candidates HONUA_SCALE_TEST_REDIS "$terraform_output_json" redis_connection_string scale_test_redis redis
}

render_control_plane_config_from_terraform() {
  local validation_root="$1"
  local terraform_output_json="${HONUA_PLATFORM_VALIDATION_TERRAFORM_OUTPUT_JSON:-}"
  local render_script="${HONUA_PLATFORM_VALIDATION_RENDER_CONTROL_PLANE_SCRIPT:-$validation_root/scripts/render-control-plane-config-from-terraform.sh}"
  local rendered_config_path="${HONUA_PLATFORM_VALIDATION_CONTROL_PLANE_CONFIG_OUTPUT:-}"
  local rendered_target_id=""
  local rendered_current_revision=""
  local rendered_desired_revision=""
  local rendered_slot_name=""
  local platform="${HONUA_PLATFORM_VALIDATION_PLATFORM:-${HONUA_CLOUD_TEST_PLATFORM:-}}"
  local should_export_target_id="true"
  local -a render_args

  if [[ -z "$terraform_output_json" ]]; then
    return 0
  fi

  if [[ ! -f "$terraform_output_json" ]]; then
    platform_validation_log warn "Skipping control-plane config render because Terraform output JSON was not found: $terraform_output_json"
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

  if [[ "$platform" == "azure-functions" && -z "${HONUA_PLATFORM_VALIDATION_DEPLOY_TARGET_ID:-}" ]]; then
    rendered_slot_name="$(
      jq -r '
        .control_plane_slot_name.value //
        .function_app_slot_name.value //
        .control_plane_desired_revision.value //
        empty
      ' "$terraform_output_json"
    )"
    if [[ -z "$rendered_slot_name" ]]; then
      should_export_target_id="false"
      export HONUA_CLOUD_TEST_EXPECT_DEPLOY_PLAN_SUPPORT="false"
      platform_validation_log info "Skipping derived deploy target id for Azure Functions because no deployment slot outputs were provisioned"
    fi
  fi

  if rendered_target_id="$(jq -r '.ControlPlane.DeployTargets[0].TargetId // empty' "$rendered_config_path")" && [[ -n "$rendered_target_id" ]]; then
    if [[ "$should_export_target_id" == "true" ]]; then
      export HONUA_CLOUD_TEST_DEPLOY_TARGET_ID="$rendered_target_id"
      platform_validation_log info "Derived deploy target id '$rendered_target_id' from Terraform outputs"
    else
      unset HONUA_CLOUD_TEST_DEPLOY_TARGET_ID
    fi
  fi

  if [[ -z "${HONUA_CLOUD_TEST_DEPLOY_CURRENT_REVISION:-}" ]]; then
    rendered_current_revision="$(
      jq -r '
        .lambda_alias_function_version.value //
        .control_plane_current_revision.value //
        .lambda_function_version.value //
        empty
      ' "$terraform_output_json"
    )"
    if [[ -n "$rendered_current_revision" ]]; then
      export HONUA_CLOUD_TEST_DEPLOY_CURRENT_REVISION="$rendered_current_revision"
      platform_validation_log info "Derived current deploy revision '$rendered_current_revision' from Terraform outputs"
    fi
  fi

  if [[ -z "${HONUA_CLOUD_TEST_DEPLOY_DESIRED_REVISION:-}" ]]; then
    rendered_desired_revision="$(
      jq -r '
        .control_plane_desired_revision.value //
        .lambda_function_version.value //
        .control_plane_current_revision.value //
        .lambda_alias_function_version.value //
        empty
      ' "$terraform_output_json"
    )"
    if [[ -n "$rendered_desired_revision" ]]; then
      export HONUA_CLOUD_TEST_DEPLOY_DESIRED_REVISION="$rendered_desired_revision"
      platform_validation_log info "Derived desired deploy revision '$rendered_desired_revision' from Terraform outputs"
    fi
  fi

  platform_validation_log info "Rendered control-plane config fragment at $rendered_config_path"
}

run_filtered_cloud_post_apply_validation() {
  local validation_root="$1"
  local include_scale_tests="${2:-false}"
  local cloud_test_filter="Category=Cloud"

  cd "$validation_root"

  if [[ "${HONUA_CLOUD_TEST_PLATFORM:-}" == "azure-functions" && "${HONUA_CLOUD_TEST_EXPECT_DEPLOY_PLAN_SUPPORT:-}" == "false" ]]; then
    cloud_test_filter="${cloud_test_filter}&FullyQualifiedName!=Honua.Server.Tests.Cloud.CloudDeploymentValidationTests.DeployPlanEndpoint_ReturnsPlan_WhenTargetConfigured_OrNotFoundContract_WhenNoTargetConfigured"
    platform_validation_log info "Skipping Azure Functions deploy-plan cloud test because the validation deployment did not provision a rollout target"
  fi

  chmod +x scripts/post-deployment-verification.sh
  scripts/post-deployment-verification.sh

  dotnet test tests/Honua.Server.Tests/Honua.Server.Tests.csproj \
    -p:RunAnalyzers=false \
    --filter "$cloud_test_filter"

  if [[ "$include_scale_tests" == "true" ]]; then
    if [[ -z "${HONUA_SCALE_TEST_BASE_URL:-}" ]]; then
      echo "INCLUDE_SCALE_TESTS=true but HONUA_SCALE_TEST_BASE_URL is not set." >&2
      return 1
    fi

    echo "Running scale validation against ${HONUA_SCALE_TEST_BASE_URL}"
    dotnet test tests/Honua.Server.Tests/Honua.Server.Tests.csproj \
      -p:RunAnalyzers=false \
      --filter "Category=Scale"
  fi

  echo "Cloud post-apply validation completed successfully."
}

run_honua_platform_post_apply_validation() {
  local base_url="$1"
  local default_platform="${2:-}"
  local validation_runner="${HONUA_PLATFORM_VALIDATION_SCRIPT:-}"
  local validation_root
  local effective_platform
  local include_scale_tests
  local normalized_tf_output_json=""
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

  if ! validation_root="$(resolve_platform_validation_root "$validation_runner")"; then
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

  (
    set -euo pipefail

    cd "$validation_root"

    export HONUA_CLOUD_TEST_BASE_URL="$base_url"

    if [[ -n "${HONUA_PLATFORM_VALIDATION_TERRAFORM_OUTPUT_JSON:-}" ]]; then
      normalized_tf_output_json="$(normalize_platform_validation_terraform_output_json "$HONUA_PLATFORM_VALIDATION_TERRAFORM_OUTPUT_JSON")"
      if [[ -n "$normalized_tf_output_json" ]]; then
        export HONUA_PLATFORM_VALIDATION_TERRAFORM_OUTPUT_JSON="$normalized_tf_output_json"
        runner_args+=(--terraform-output-json "$normalized_tf_output_json")
      fi
    fi

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

    export_platform_validation_env_from_terraform_output

    if [[ -n "$effective_platform" && -z "${HONUA_CLOUD_TEST_PLATFORM:-}" ]]; then
      export HONUA_CLOUD_TEST_PLATFORM="$effective_platform"
    fi

    export_platform_validation_contract "$effective_platform"

    render_control_plane_config_from_terraform "$validation_root"

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

    if [[ "$effective_platform" == "azure-functions" && "${HONUA_CLOUD_TEST_EXPECT_DEPLOY_PLAN_SUPPORT:-}" == "false" ]]; then
      run_filtered_cloud_post_apply_validation "$validation_root" "$include_scale_tests"
    else
      bash "./scripts/run-cloud-post-apply-validation.sh" "${runner_args[@]}"
    fi
  )
}
