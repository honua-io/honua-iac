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
  local terraform_output_json="${HONUA_PLATFORM_VALIDATION_TERRAFORM_OUTPUT_JSON:-}"
  local render_script="${HONUA_PLATFORM_VALIDATION_RENDER_CONTROL_PLANE_SCRIPT:-$validation_root/scripts/render-control-plane-config-from-terraform.sh}"
  local rendered_config_path="${HONUA_PLATFORM_VALIDATION_CONTROL_PLANE_CONFIG_OUTPUT:-}"
  local rendered_target_id=""
  local rendered_current_revision=""
  local rendered_desired_revision=""
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

  if rendered_target_id="$(jq -r '.ControlPlane.DeployTargets[0].TargetId // empty' "$rendered_config_path")" && [[ -n "$rendered_target_id" ]]; then
    export HONUA_CLOUD_TEST_DEPLOY_TARGET_ID="$rendered_target_id"
    platform_validation_log info "Derived deploy target id '$rendered_target_id' from Terraform outputs"
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

run_honua_platform_post_apply_validation() {
  local base_url="$1"
  local default_platform="${2:-}"
  local validation_runner="${HONUA_PLATFORM_VALIDATION_SCRIPT:-}"
  local validation_root
  local effective_platform
  local include_scale_tests
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

    case "$effective_platform" in
      azure-functions)
        export HONUA_CLOUD_TEST_EXPECT_DEPLOY_PLAN_SUPPORT="${HONUA_PLATFORM_VALIDATION_EXPECT_DEPLOY_PLAN_SUPPORT:-false}"
        export HONUA_CLOUD_TEST_EXPECT_MUTATION_SUPPORT="${HONUA_PLATFORM_VALIDATION_EXPECT_MUTATION_SUPPORT:-false}"
        ;;
      *)
        if [[ -n "${HONUA_PLATFORM_VALIDATION_EXPECT_DEPLOY_PLAN_SUPPORT:-}" ]]; then
          export HONUA_CLOUD_TEST_EXPECT_DEPLOY_PLAN_SUPPORT="$HONUA_PLATFORM_VALIDATION_EXPECT_DEPLOY_PLAN_SUPPORT"
        fi

        if [[ -n "${HONUA_PLATFORM_VALIDATION_EXPECT_MUTATION_SUPPORT:-}" ]]; then
          export HONUA_CLOUD_TEST_EXPECT_MUTATION_SUPPORT="$HONUA_PLATFORM_VALIDATION_EXPECT_MUTATION_SUPPORT"
        fi
        ;;
    esac

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

    bash "./scripts/run-cloud-post-apply-validation.sh" "${runner_args[@]}"
  )
}
