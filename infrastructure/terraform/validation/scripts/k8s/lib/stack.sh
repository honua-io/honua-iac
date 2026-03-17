# Sourced by validation.sh after common, check, and Helm helpers are defined.

prepare_tf_workspace() {
  local docker_source

  TEMP_WORK_ROOT="$(mktemp -d)"
  TEMP_REPO_ROOT="$TEMP_WORK_ROOT/honua-server"

  mkdir -p "$TEMP_REPO_ROOT/infrastructure"
  cp -R "$REPO_ROOT/infrastructure/terraform" "$TEMP_REPO_ROOT/infrastructure/terraform"

  docker_source="$REPO_ROOT/docker"
  if [[ ! -d "$docker_source" ]]; then
    docker_source="$REPO_ROOT/honua-server/docker"
  fi

  if [[ ! -d "$docker_source" ]]; then
    docker_source="$(dirname "$REPO_ROOT")/honua-server/docker"
  fi

  if [[ ! -d "$docker_source" ]]; then
    log_error "Could not resolve docker asset path. Check out honua-server inside or next to honua-terraform."
    return 1
  fi

  cp -R "$docker_source" "$TEMP_REPO_ROOT/docker"
}

create_cluster() {
  if [[ "$CLUSTER_MODE" == "external" ]]; then
    if [[ -n "$KUBE_CONTEXT" ]]; then
      kubectl config use-context "$KUBE_CONTEXT" >/dev/null
    fi
    return
  fi

  if k3d cluster list | awk 'NR>1 {print $1}' | grep -qx "$CLUSTER_NAME"; then
    log_warn "k3d cluster '$CLUSTER_NAME' already exists; tests will reuse it"
  else
    CLUSTER_CREATED=true
  fi

  CLUSTER_NAME="$CLUSTER_NAME" \
  K3D_HTTP_PORT="$HTTP_PORT" \
  K3D_HTTPS_PORT="$HTTPS_PORT" \
  K3D_API_PORT="$API_PORT" \
  K3D_NO_LB="$([[ "$ACCESS_MODE" == "port-forward" ]] && echo true || echo false)" \
    "$K8S_HELPER_DIR/k3d-up.sh"

  kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
}

run_stack_checks() {
  local label="$1"
  local do_load="$2"

  wait_for_ready

  if [[ "$CHECK_PROTOCOLS" == "true" ]]; then
    verify_protocol_endpoints
    run_admin_api_crud_smoke
  fi

  verify_postgis_extensions

  if [[ "$RUN_DB_RESILIENCE" == "true" ]]; then
    verify_db_backup_restore
  fi

  if [[ "$do_load" == "true" ]]; then
    run_load_probe "$LOAD_REQUESTS" "$LOAD_CONCURRENCY"
  fi

  log_info "Stack checks passed for phase: $label"
}

run_scale_check() {
  local available
  local baseline_replicas

  if [[ "$QUICK_SCALE" != "true" ]]; then
    return
  fi

  baseline_replicas="$(kubectl -n "$NAMESPACE" get "deployment/${HONUA_DEPLOYMENT_NAME}" -o jsonpath='{.spec.replicas}')"
  if [[ -z "$baseline_replicas" ]]; then
    baseline_replicas=1
  fi

  log_info "Running quick k8s scale validation by raising replicas to $SCALE_TARGET_REPLICAS"
  kubectl -n "$NAMESPACE" scale "deployment/${HONUA_DEPLOYMENT_NAME}" --replicas="$SCALE_TARGET_REPLICAS"
  kubectl -n "$NAMESPACE" rollout status "deployment/${HONUA_DEPLOYMENT_NAME}" --timeout="${TIMEOUT_SECONDS}s"

  available="$(kubectl -n "$NAMESPACE" get "deployment/${HONUA_DEPLOYMENT_NAME}" -o jsonpath='{.status.availableReplicas}')"
  if [[ -z "$available" || "$available" -lt "$SCALE_TARGET_REPLICAS" ]]; then
    log_error "Expected available replicas >= $SCALE_TARGET_REPLICAS, observed: ${available:-0}"
    return 1
  fi

  log_info "Scale check passed with available replicas: $available"

  if [[ "$baseline_replicas" != "$SCALE_TARGET_REPLICAS" ]]; then
    log_info "Restoring deployment replicas to baseline: $baseline_replicas"
    kubectl -n "$NAMESPACE" scale "deployment/${HONUA_DEPLOYMENT_NAME}" --replicas="$baseline_replicas"
    kubectl -n "$NAMESPACE" rollout status "deployment/${HONUA_DEPLOYMENT_NAME}" --timeout="${TIMEOUT_SECONDS}s"
  fi
}

deploy_honua_stack() {
  log_info "Deploying k8s PostGIS and Honua Helm release"

  NAMESPACE="$NAMESPACE" "$K8S_HELPER_DIR/postgis-up.sh"
  POSTGIS_APPLIED=true

  if [[ "$RUN_UPGRADE_ROLLBACK" == "true" ]]; then
    if [[ -z "$PREVIOUS_IMAGE" ]]; then
      log_error "Upgrade/rollback requested but no previous image provided (use --previous-image or HONUA_K8S_PREVIOUS_IMAGE)"
      return 1
    fi

    if [[ "$PREVIOUS_IMAGE" == "$HONUA_IMAGE" ]]; then
      log_error "Upgrade/rollback requires previous image different from current image"
      return 1
    fi

    deploy_honua_release "$PREVIOUS_IMAGE_REPOSITORY" "$PREVIOUS_IMAGE_TAG" "previous"
    run_stack_checks "previous" "false"

    deploy_honua_release "$HONUA_IMAGE_REPOSITORY" "$HONUA_IMAGE_TAG" "upgrade"
    run_stack_checks "upgrade" "true"
    run_scale_check

    deploy_honua_release "$PREVIOUS_IMAGE_REPOSITORY" "$PREVIOUS_IMAGE_TAG" "rollback"
    run_stack_checks "rollback" "false"

    if [[ "$AUTO_DESTROY" != "true" ]]; then
      deploy_honua_release "$HONUA_IMAGE_REPOSITORY" "$HONUA_IMAGE_TAG" "restore-current"
      run_stack_checks "restore-current" "false"
    fi
  else
    deploy_honua_release "$HONUA_IMAGE_REPOSITORY" "$HONUA_IMAGE_TAG" "current"
    run_stack_checks "current" "true"
    run_scale_check
  fi

  log_info "Honua Helm stack checks passed"
}

apply_observability_stack() {
  local root
  root="$TEMP_REPO_ROOT/infrastructure/terraform/stacks/test/observability"

  log_info "Applying Terraform observability stack against Kubernetes cluster"

  export TF_VAR_kubeconfig_path="$KUBECONFIG_PATH"
  export TF_VAR_namespace="$OBS_NAMESPACE"
  export TF_VAR_honua_metrics_target="${HONUA_SERVICE_NAME}.${NAMESPACE}.svc.cluster.local:80"
  export TF_VAR_grafana_ingress_host=""
  export TF_VAR_alertmanager_enabled=false
  export TF_VAR_prometheus_persistence_enabled=false
  export TF_VAR_grafana_persistence_enabled=false
  export TF_VAR_helm_timeout_seconds="$TIMEOUT_SECONDS"

  terraform -chdir="$root" init -input=false -no-color
  terraform -chdir="$root" plan -input=false -no-color -out=observability.tfplan
  terraform -chdir="$root" apply -input=false -auto-approve -no-color observability.tfplan

  OBS_APPLIED=true

  kubectl -n "$OBS_NAMESPACE" wait --for=condition=Ready pod -l app.kubernetes.io/instance=honua-prometheus --timeout="${TIMEOUT_SECONDS}s"
  kubectl -n "$OBS_NAMESPACE" wait --for=condition=Ready pod -l app.kubernetes.io/instance=honua-grafana --timeout="${TIMEOUT_SECONDS}s"
  kubectl -n "$OBS_NAMESPACE" get configmap honua-overview-dashboard >/dev/null

  if [[ "$CHECK_IDEMPOTENCY" == "true" ]]; then
    assert_idempotent_plan "$root"
  fi

  log_info "Observability Terraform stack checks passed"
}

destroy_observability_stack() {
  local root
  root="$TEMP_REPO_ROOT/infrastructure/terraform/stacks/test/observability"

  if [[ "$OBS_APPLIED" != "true" ]]; then
    return
  fi

  log_info "Destroying Terraform observability stack"
  export TF_VAR_kubeconfig_path="$KUBECONFIG_PATH"
  export TF_VAR_namespace="$OBS_NAMESPACE"
  export TF_VAR_honua_metrics_target="${HONUA_SERVICE_NAME}.${NAMESPACE}.svc.cluster.local:80"
  export TF_VAR_grafana_ingress_host=""
  export TF_VAR_alertmanager_enabled=false
  export TF_VAR_prometheus_persistence_enabled=false
  export TF_VAR_grafana_persistence_enabled=false
  export TF_VAR_helm_timeout_seconds="$TIMEOUT_SECONDS"
  terraform -chdir="$root" destroy -input=false -auto-approve -no-color || log_warn "Observability destroy encountered errors"
}

destroy_honua_stack() {
  stop_port_forward

  if [[ "$HONUA_APPLIED" == "true" ]]; then
    log_info "Uninstalling Honua Helm release"
    helm uninstall "$RELEASE_NAME" --namespace "$NAMESPACE" || log_warn "Helm uninstall encountered errors"
  fi

  if [[ "$POSTGIS_APPLIED" == "true" ]]; then
    log_info "Removing PostGIS deployment"
    NAMESPACE="$NAMESPACE" "$K8S_HELPER_DIR/postgis-down.sh" || log_warn "PostGIS cleanup encountered errors"
  fi
}

destroy_cluster() {
  if [[ "$CLUSTER_MODE" != "k3d" ]]; then
    return
  fi

  if [[ "$CLUSTER_CREATED" != "true" ]]; then
    log_warn "Cluster '$CLUSTER_NAME' existed before test run; skipping cluster deletion"
    return
  fi

  log_info "Deleting k3d cluster '$CLUSTER_NAME'"
  CLUSTER_NAME="$CLUSTER_NAME" "$K8S_HELPER_DIR/k3d-down.sh" || log_warn "k3d cluster deletion encountered errors"
}

cleanup() {
  local exit_code="$?"

  stop_port_forward

  if [[ "$AUTO_DESTROY" == "true" ]]; then
    destroy_observability_stack
    destroy_honua_stack
    destroy_cluster
  else
    log_warn "Auto-destroy disabled; cluster/resources left running"
    log_warn "Temporary workspace retained at: $TEMP_WORK_ROOT"
  fi

  if [[ "$AUTO_DESTROY" == "true" && -n "$TEMP_WORK_ROOT" && -d "$TEMP_WORK_ROOT" ]]; then
    rm -rf "$TEMP_WORK_ROOT" || true
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    log_error "Kubernetes Terraform integration run failed"
  fi

  exit "$exit_code"
}
