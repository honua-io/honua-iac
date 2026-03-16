# Sourced by validation.sh after common and check helpers are defined.

run_helm_static_validation() {
  local chart_path
  local rendered
  local ingress_class
  local kubeconform_image
  local kubeconform_command
  local -a pull_secret_args=()

  if [[ "$HELM_STATIC_VALIDATE" != "true" ]]; then
    return
  fi

  chart_path="$HELM_CHART_PATH"
  kubeconform_image="${HONUA_KUBECONFORM_IMAGE:-ghcr.io/yannh/kubeconform:v0.7.0}"

  ingress_class="traefik"
  if [[ "$CLUSTER_MODE" != "k3d" ]]; then
    ingress_class="nginx"
  fi

  rendered="$(mktemp)"

  if [[ -n "$HONUA_IMAGE_PULL_SECRET_NAME" ]]; then
    pull_secret_args+=(--set image.pullSecrets[0].name="$HONUA_IMAGE_PULL_SECRET_NAME")
  fi

  helm dependency update "$chart_path" >/dev/null

  helm lint "$chart_path" \
    --set ingress.enabled=true \
    --set ingress.className="$ingress_class" \
    --set ingress.hosts[0].host="$INGRESS_HOSTNAME" \
    --set ingress.hosts[0].paths[0].path='/' \
    --set ingress.hosts[0].paths[0].pathType='Prefix' \
    --set postgresql.enabled=false \
    --set-string secret.env.ConnectionStrings__DefaultConnection='Host=honua-postgis;Port=5432;Database=honua;Username=honua;Password=honua' \
    --set secret.env.HONUA_ADMIN_PASSWORD="$K8S_ADMIN_PASSWORD" \
    --set-string secret.env.Security__ConnectionEncryption__MasterKey="$K8S_MASTER_KEY" \
    --set image.repository="$HONUA_IMAGE_REPOSITORY" \
    --set image.tag="$HONUA_IMAGE_TAG" \
    "${pull_secret_args[@]}" >/dev/null

  helm template "$RELEASE_NAME" "$chart_path" \
    --namespace "$NAMESPACE" \
    --set ingress.enabled=true \
    --set ingress.className="$ingress_class" \
    --set ingress.hosts[0].host="$INGRESS_HOSTNAME" \
    --set ingress.hosts[0].paths[0].path='/' \
    --set ingress.hosts[0].paths[0].pathType='Prefix' \
    --set postgresql.enabled=false \
    --set-string secret.env.ConnectionStrings__DefaultConnection='Host=honua-postgis;Port=5432;Database=honua;Username=honua;Password=honua' \
    --set secret.env.HONUA_ADMIN_PASSWORD="$K8S_ADMIN_PASSWORD" \
    --set-string secret.env.Security__ConnectionEncryption__MasterKey="$K8S_MASTER_KEY" \
    --set image.repository="$HONUA_IMAGE_REPOSITORY" \
    --set image.tag="$HONUA_IMAGE_TAG" \
    "${pull_secret_args[@]}" > "$rendered"

  if command -v kubeconform >/dev/null 2>&1; then
    kubeconform_command=(kubeconform -strict -summary -ignore-missing-schemas)
    "${kubeconform_command[@]}" < "$rendered" >/dev/null
  else
    docker run --rm -i "$kubeconform_image" -strict -summary -ignore-missing-schemas < "$rendered" >/dev/null
  fi
  rm -f "$rendered"

  log_info "Helm static validation passed (lint + kubeconform)"
}

ensure_image_pull_secret() {
  if [[ -z "$HONUA_IMAGE_PULL_SECRET_NAME" ]]; then
    return 0
  fi

  if [[ -z "$HONUA_IMAGE_PULL_SECRET_SERVER" || -z "$HONUA_IMAGE_PULL_SECRET_USERNAME" || -z "$HONUA_IMAGE_PULL_SECRET_PASSWORD" ]]; then
    log_error "Image pull secret '$HONUA_IMAGE_PULL_SECRET_NAME' is configured, but registry credentials are incomplete"
    return 1
  fi

  kubectl -n "$NAMESPACE" create secret docker-registry "$HONUA_IMAGE_PULL_SECRET_NAME" \
    --docker-server="$HONUA_IMAGE_PULL_SECRET_SERVER" \
    --docker-username="$HONUA_IMAGE_PULL_SECRET_USERNAME" \
    --docker-password="$HONUA_IMAGE_PULL_SECRET_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

honua_selector() {
  printf 'app.kubernetes.io/instance=%s,app.kubernetes.io/name=honua' "$RELEASE_NAME"
}

dump_honua_rollout_diagnostics() {
  local selector
  local pod
  local pods

  selector="$(honua_selector)"

  log_warn "Dumping Honua rollout diagnostics for namespace '${NAMESPACE}'"
  kubectl -n "$NAMESPACE" get deployment "$HONUA_DEPLOYMENT_NAME" -o wide || true
  kubectl -n "$NAMESPACE" describe deployment "$HONUA_DEPLOYMENT_NAME" || true
  kubectl -n "$NAMESPACE" get pods -l "$selector" -o wide || true
  kubectl -n "$NAMESPACE" describe pods -l "$selector" || true

  pods="$(kubectl -n "$NAMESPACE" get pods -l "$selector" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  for pod in $pods; do
    log_warn "Recent logs for pod ${pod}"
    kubectl -n "$NAMESPACE" logs "$pod" --all-containers --tail=200 || true
    kubectl -n "$NAMESPACE" logs "$pod" --all-containers --tail=200 --previous || true
  done

  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -n 50 || true
}

honua_rollout_has_image_pull_failure() {
  local pod_describe

  pod_describe="$(kubectl -n "$NAMESPACE" describe pods -l "$(honua_selector)" 2>/dev/null || true)"
  grep -Eqi 'ErrImagePull|ImagePullBackOff|Failed to pull image|pull access denied|authentication required|unauthorized' <<<"$pod_describe"
}

wait_for_honua_rollout() {
  local image_repository="$1"

  if kubectl -n "$NAMESPACE" rollout status "deployment/${HONUA_DEPLOYMENT_NAME}" --timeout="${TIMEOUT_SECONDS}s"; then
    return 0
  fi

  dump_honua_rollout_diagnostics

  if [[ -z "$HONUA_IMAGE_PULL_SECRET_NAME" && "$image_repository" == *.azurecr.io/* ]] && honua_rollout_has_image_pull_failure; then
    log_warn "Detected Azure Container Registry pull failures while relying on managed AcrPull; waiting for role propagation and retrying once"
    sleep 90
    kubectl -n "$NAMESPACE" delete pod -l "$(honua_selector)" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true

    if kubectl -n "$NAMESPACE" rollout status "deployment/${HONUA_DEPLOYMENT_NAME}" --timeout="${TIMEOUT_SECONDS}s"; then
      return 0
    fi

    dump_honua_rollout_diagnostics
  fi

  return 1
}

deploy_honua_release() {
  local image_repository="$1"
  local image_tag="$2"
  local label="$3"
  local ingress_class

  ingress_class="traefik"
  if [[ "$CLUSTER_MODE" != "k3d" ]]; then
    ingress_class="nginx"
  fi

  ensure_image_pull_secret

  NAMESPACE="$NAMESPACE" \
    RELEASE_NAME="$RELEASE_NAME" \
    CHART_PATH="$HELM_CHART_PATH" \
    INGRESS_CLASS="$ingress_class" \
    INGRESS_HOSTNAME="$INGRESS_HOSTNAME" \
    LOCAL_HTTP_PORT="$HTTP_PORT" \
    POSTGRESQL_ENABLED="false" \
  DEFAULT_CONNECTION_STRING="Host=honua-postgis;Port=5432;Database=honua;Username=honua;Password=honua" \
  HONUA_ADMIN_PASSWORD="$K8S_ADMIN_PASSWORD" \
  SECURITY_MASTER_KEY="$K8S_MASTER_KEY" \
  HONUA_IMAGE_REPOSITORY="$image_repository" \
  HONUA_IMAGE_TAG="$image_tag" \
  HONUA_IMAGE_PULL_SECRET_NAME="$HONUA_IMAGE_PULL_SECRET_NAME" \
    "$K8S_HELPER_DIR/helm-install.sh"

  HONUA_APPLIED=true

  HONUA_DEPLOYMENT_NAME="$(kubectl -n "$NAMESPACE" get deployment -l "app.kubernetes.io/instance=${RELEASE_NAME},app.kubernetes.io/name=honua" -o jsonpath='{.items[0].metadata.name}')"
  HONUA_SERVICE_NAME="$(kubectl -n "$NAMESPACE" get service -l "app.kubernetes.io/instance=${RELEASE_NAME},app.kubernetes.io/name=honua" -o jsonpath='{.items[0].metadata.name}')"

  if [[ -z "$HONUA_DEPLOYMENT_NAME" || -z "$HONUA_SERVICE_NAME" ]]; then
    log_error "Failed to resolve Honua deployment/service names"
    return 1
  fi

  wait_for_honua_rollout "$image_repository"
  RELEASE_NAME="$RELEASE_NAME" NAMESPACE="$NAMESPACE" "$K8S_HELPER_DIR/helm-test.sh"
  start_port_forward

  log_info "Release deployment complete for phase: $label"
}
