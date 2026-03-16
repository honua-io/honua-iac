# Sourced by validation.sh after common globals,
# logging helpers, and shared post-apply validation helpers are defined.

resolve_helm_chart_path() {
  local candidate
  local -a candidates=()

  if [[ -n "$HELM_CHART_PATH" ]]; then
    candidates+=("$HELM_CHART_PATH")
  fi

  candidates+=(
    "$REPO_ROOT/infrastructure/helm/honua"
    "$REPO_ROOT/honua-server/infrastructure/helm/honua"
    "$(dirname "$REPO_ROOT")/honua-server/infrastructure/helm/honua"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate/Chart.yaml" ]]; then
      HELM_CHART_PATH="$candidate"
      return 0
    fi
  done

  log_error "Could not resolve Helm chart path. Set HONUA_HELM_CHART_PATH or check out honua-server inside or next to honua-terraform."
  return 1
}

apply_aot_mode() {
  if [[ "$USE_AOT" != "true" ]]; then
    return
  fi

  if [[ "$HONUA_IMAGE" == "$DEFAULT_HONUA_IMAGE" ]]; then
    HONUA_IMAGE="$DEFAULT_HONUA_AOT_IMAGE"
  fi
}

validate_requested_images() {
  if [[ -z "$HONUA_IMAGE" ]]; then
    log_error "Kubernetes image is required. Set HONUA_K8S_IMAGE or pass --image."
    exit 1
  fi

  if [[ "$RUN_UPGRADE_ROLLBACK" == "true" && -z "$PREVIOUS_IMAGE" ]]; then
    log_error "Upgrade/rollback requires HONUA_K8S_PREVIOUS_IMAGE or --previous-image."
    exit 1
  fi
}

parse_image() {
  local image="$1"
  local repo_var="$2"
  local tag_var="$3"

  if [[ "$image" == *"@"* ]]; then
    log_error "Image digest format is not supported in this script. Provide image as repository:tag."
    exit 1
  fi

  if [[ "$image" != *":"* ]]; then
    log_error "Image must include a tag. Example: ghcr.io/honua-io/honua-server:latest"
    exit 1
  fi

  local repo="${image%:*}"
  local tag="${image##*:}"

  if [[ -z "$repo" || -z "$tag" || "$tag" == "$image" ]]; then
    log_error "Failed to parse image repository/tag from: $image"
    exit 1
  fi

  printf -v "$repo_var" "%s" "$repo"
  printf -v "$tag_var" "%s" "$tag"
}

resolve_k8s_helper_dir() {
  K8S_HELPER_DIR="$SCRIPT_DIR/k8s"
  if [[ -d "$K8S_HELPER_DIR" ]]; then
    return
  fi

  log_error "Could not locate helper scripts directory: $K8S_HELPER_DIR"
  exit 1
}

resolve_secret_values() {
  K8S_ADMIN_PASSWORD="${HONUA_ADMIN_PASSWORD:-}"
  if [[ -z "$K8S_ADMIN_PASSWORD" ]]; then
    log_error "HONUA_ADMIN_PASSWORD must be set for validation runs."
    exit 1
  elif (( ${#K8S_ADMIN_PASSWORD} < 12 )); then
    log_error "HONUA_ADMIN_PASSWORD must be at least 12 characters."
    exit 1
  fi

  K8S_MASTER_KEY="${SECURITY_MASTER_KEY:-$K8S_ADMIN_PASSWORD}"
  if (( ${#K8S_MASTER_KEY} < 32 )); then
    log_error "SECURITY_MASTER_KEY (or HONUA_ADMIN_PASSWORD fallback) must be at least 32 characters."
    exit 1
  fi
}
