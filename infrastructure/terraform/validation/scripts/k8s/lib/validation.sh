# Sourced by run-k8s-terraform-integration.sh after common globals,
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

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "Required command not found: $1"
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

assert_idempotent_plan() {
  local root="$1"
  local log_file
  local exit_code

  log_file="$(mktemp)"
  set +e
  terraform -chdir="$root" plan -input=false -no-color -detailed-exitcode >"$log_file" 2>&1
  exit_code=$?
  set -e

  if [[ "$exit_code" -eq 0 ]]; then
    log_info "Idempotency check passed for $root (no changes)"
    rm -f "$log_file"
    return 0
  fi

  if [[ "$exit_code" -eq 2 ]]; then
    log_error "Idempotency check failed for $root (terraform reports pending changes)"
    cat "$log_file"
    rm -f "$log_file"
    return 1
  fi

  log_error "Idempotency plan errored for $root"
  cat "$log_file"
  rm -f "$log_file"
  return 1
}

http_base_url() {
  if [[ "$ACCESS_MODE" == "port-forward" ]]; then
    echo "http://localhost:${FORWARD_PORT}"
  else
    echo "http://localhost:${HTTP_PORT}"
  fi
}

run_load_probe() {
  local requests="$1"
  local concurrency="$2"
  local fail_file
  local failures
  local error_rate
  local url
  local pid
  local pids=()
  local curl_args=()

  url="$(http_base_url)/healthz/ready"
  if [[ "$ACCESS_MODE" == "ingress" ]]; then
    curl_args=(-H "Host: ${INGRESS_HOSTNAME}")
  fi

  fail_file="$(mktemp)"

  for ((i = 1; i <= requests; i++)); do
    (
      if ! curl -fsS --max-time 20 "${curl_args[@]}" "$url" >/dev/null; then
        echo "1" >> "$fail_file"
      fi
    ) &
    pids+=("$!")

    if (( ${#pids[@]} >= concurrency )); then
      for pid in "${pids[@]}"; do
        wait "$pid"
      done
      pids=()
    fi
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  failures="$(wc -l < "$fail_file" | tr -d ' ')"
  rm -f "$fail_file"

  error_rate="$(awk -v f="$failures" -v r="$requests" 'BEGIN { printf "%.4f", (f*100)/r }')"
  if awk -v e="$error_rate" -v m="$MAX_LOAD_ERROR_RATE_PERCENT" 'BEGIN { exit !(e <= m) }'; then
    log_info "Load probe passed: $requests requests, concurrency $concurrency, error rate ${error_rate}%"
    return 0
  fi

  log_error "Load probe failed SLO: error rate ${error_rate}% exceeds ${MAX_LOAD_ERROR_RATE_PERCENT}%"
  return 1
}

start_port_forward() {
  local attempt

  if [[ "$ACCESS_MODE" != "port-forward" ]]; then
    return
  fi

  stop_port_forward

  PORT_FORWARD_LOG="$(mktemp)"
  kubectl -n "$NAMESPACE" port-forward "svc/${HONUA_SERVICE_NAME}" "${FORWARD_PORT}:80" >"$PORT_FORWARD_LOG" 2>&1 &
  PORT_FORWARD_PID=$!

  log_info "Started port-forward pid=$PORT_FORWARD_PID on localhost:$FORWARD_PORT -> svc/${HONUA_SERVICE_NAME}:80"

  for attempt in $(seq 1 30); do
    if ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
      log_error "Port-forward process exited before becoming ready"
      if [[ -s "$PORT_FORWARD_LOG" ]]; then
        cat "$PORT_FORWARD_LOG" >&2
      fi
      return 1
    fi

    if grep -q "Forwarding from 127.0.0.1:${FORWARD_PORT}" "$PORT_FORWARD_LOG" 2>/dev/null; then
      return 0
    fi

    sleep 1
  done

  log_error "Timed out waiting for port-forward on localhost:$FORWARD_PORT"
  if [[ -s "$PORT_FORWARD_LOG" ]]; then
    cat "$PORT_FORWARD_LOG" >&2
  fi
  return 1
}

stop_port_forward() {
  if [[ -z "$PORT_FORWARD_PID" ]]; then
    return
  fi

  kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
  wait "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
  PORT_FORWARD_PID=""

  if [[ -n "$PORT_FORWARD_LOG" && -f "$PORT_FORWARD_LOG" ]]; then
    rm -f "$PORT_FORWARD_LOG" || true
  fi
  PORT_FORWARD_LOG=""
}

wait_for_ready() {
  local start_epoch
  local elapsed
  local url
  local curl_args=()

  url="$(http_base_url)/healthz/ready"
  if [[ "$ACCESS_MODE" == "ingress" ]]; then
    curl_args=(-H "Host: ${INGRESS_HOSTNAME}")
  fi

  start_epoch="$(date +%s)"
  while true; do
    if curl -fsS --max-time 20 "${curl_args[@]}" "$url" >/dev/null; then
      elapsed=$(( $(date +%s) - start_epoch ))
      if (( elapsed > READY_SLO_SECONDS )); then
        log_error "Ready SLO failed: ${elapsed}s exceeds ${READY_SLO_SECONDS}s"
        return 1
      fi
      log_info "Ready check passed in ${elapsed}s: $url"
      return 0
    fi

    if (( $(date +%s) - start_epoch > TIMEOUT_SECONDS )); then
      log_error "Timed out waiting for readiness: $url"
      return 1
    fi

    sleep 10
  done
}

verify_protocol_endpoints() {
  local status
  local base
  local admin_api_key
  local curl_args=()

  base="$(http_base_url)"
  admin_api_key="$K8S_ADMIN_PASSWORD"
  if [[ "$ACCESS_MODE" == "ingress" ]]; then
    curl_args=(-H "Host: ${INGRESS_HOSTNAME}")
  fi

  check_endpoint() {
    local endpoint="$1"
    local endpoint_status

    endpoint_status="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 20 "${curl_args[@]}" "$endpoint" || true)"
    if [[ "$endpoint_status" == 2* || "$endpoint_status" == 3* ]]; then
      return 0
    fi

    if [[ "$endpoint_status" == "401" || "$endpoint_status" == "403" ]]; then
      curl -fsS --max-time 20 "${curl_args[@]}" \
        -H "X-API-Key: $admin_api_key" \
        "$endpoint" >/dev/null
      return 0
    fi

    log_error "Protocol smoke endpoint failed: $endpoint returned HTTP $endpoint_status"
    return 1
  }

  check_odata_endpoint() {
    local endpoint="$1"
    local endpoint_status
    local endpoint_body

    endpoint_status="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 20 "${curl_args[@]}" "$endpoint" || true)"
    if [[ "$endpoint_status" == 2* || "$endpoint_status" == 3* ]]; then
      return 0
    fi

    if [[ "$endpoint_status" == "401" || "$endpoint_status" == "403" ]]; then
      curl -fsS --max-time 20 "${curl_args[@]}" \
        -H "X-API-Key: $admin_api_key" \
        "$endpoint" >/dev/null
      return 0
    fi

    if [[ "$endpoint_status" == "404" ]]; then
      endpoint_body="$(curl -sS --max-time 20 "${curl_args[@]}" "$endpoint" || true)"
      if [[ "$endpoint_body" == *"OData is not enabled for any available service."* ||
            "$endpoint_body" == *"No OData-enabled services found"* ]]; then
        log_info "OData endpoint reachable with empty catalog: $endpoint returned HTTP 404"
        return 0
      fi
    fi

    log_error "Protocol smoke endpoint failed: $endpoint returned HTTP $endpoint_status"
    return 1
  }

  check_endpoint "${base}/rest/services?f=pjson"
  check_endpoint "${base}/ogc/features"
  check_odata_endpoint "${base}/odata"

  status="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 20 "${curl_args[@]}" "${base}/api/v1/admin/config")"
  if [[ "$status" != "401" && "$status" != "403" ]]; then
    log_error "Expected unauthenticated admin endpoint to return 401/403, got $status"
    return 1
  fi

  log_info "Protocol/admin smoke checks passed"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

extract_json_string_field() {
  local payload="$1"
  local field="$2"
  local compact

  compact="$(printf '%s' "$payload" | tr -d '\n\r')"
  printf '%s' "$compact" | sed -n "s/.*\"$field\":\"\\([^\"]*\\)\".*/\\1/p" | head -1
}

extract_json_number_field() {
  local payload="$1"
  local field="$2"
  local compact

  compact="$(printf '%s' "$payload" | tr -d '\n\r')"
  printf '%s' "$compact" | sed -n "s/.*\"$field\":\\([0-9][0-9]*\\).*/\\1/p" | head -1
}

run_db_sql_k8s() {
  local sql="$1"

  kubectl -n "$NAMESPACE" exec -i deployment/honua-postgis -- sh -c "PGPASSWORD=honua psql -h 127.0.0.1 -U honua -d honua -v ON_ERROR_STOP=1" >/dev/null <<SQL
$sql
SQL
}

run_admin_api_crud_smoke() {
  local base
  local admin_api_key
  local suffix
  local table_name
  local layer_name
  local service_name
  local connection_name
  local connection_id=""
  local layer_id=""
  local create_connection_payload
  local publish_layer_payload
  local create_connection_response
  local publish_layer_response
  local query_url
  local query_response
  local feature_count=0
  local curl_args=()

  base="$(http_base_url)"
  admin_api_key="$K8S_ADMIN_PASSWORD"

  if [[ "$ACCESS_MODE" == "ingress" ]]; then
    curl_args=(-H "Host: ${INGRESS_HOSTNAME}")
  fi

  suffix="$(date -u +%m%d%H%M%S)$RANDOM"
  table_name="smoke_${suffix}"
  layer_name="Smoke Layer ${suffix}"
  service_name="smoke${suffix}"
  connection_name="smoke-conn-${suffix}"

  cleanup_smoke() {
    trap - RETURN
    local had_errexit=false
    if [[ $- == *e* ]]; then
      had_errexit=true
    fi
    set +e

    local cleanup_table_name="${table_name:-}"
    local cleanup_layer_id="${layer_id:-}"
    local cleanup_service_name="${service_name:-}"
    local cleanup_connection_id="${connection_id:-}"
    local cleanup_base="${base:-}"

    if [[ -n "$cleanup_table_name" ]]; then
      run_db_sql_k8s "DROP TABLE IF EXISTS public.${cleanup_table_name};" || true
    fi

    if [[ -n "$cleanup_layer_id" ]]; then
      run_db_sql_k8s "
        DELETE FROM features WHERE layer_id = ${cleanup_layer_id};
        DELETE FROM honua.layer_fields WHERE layer_id = ${cleanup_layer_id};
        DELETE FROM honua.service_layers WHERE layer_id = ${cleanup_layer_id};
        DELETE FROM honua.layers WHERE layer_id = ${cleanup_layer_id};
      " || true
    fi

    if [[ -n "$cleanup_service_name" ]]; then
      run_db_sql_k8s "DELETE FROM honua.services WHERE service_name = '$(json_escape "$cleanup_service_name")';" || true
    fi

    if [[ -n "$cleanup_connection_id" && -n "$cleanup_base" ]]; then
      curl -sS --max-time 20 "${curl_args[@]}" -X DELETE \
        -H "X-API-Key: $admin_api_key" \
        "${cleanup_base}/api/v1/admin/connections/${cleanup_connection_id}" >/dev/null || true
    fi

    if [[ "$had_errexit" == "true" ]]; then
      set -e
    fi
  }

  trap cleanup_smoke RETURN

  run_db_sql_k8s "
    CREATE TABLE public.${table_name} (
      id SERIAL PRIMARY KEY,
      name TEXT NOT NULL,
      population INTEGER,
      geom geometry(Point, 4326) NOT NULL
    );
    INSERT INTO public.${table_name} (name, population, geom)
    VALUES ('Smoke Feature', 1, ST_SetSRID(ST_Point(1, 1), 4326));
  "

  create_connection_payload="$(cat <<JSON
{"name":"$(json_escape "$connection_name")","description":"Terraform smoke test connection","host":"honua-postgis","port":5432,"databaseName":"honua","username":"honua","password":"honua","sslRequired":false,"sslMode":"Disable"}
JSON
)"

  create_connection_response="$(curl -fsS --max-time 20 "${curl_args[@]}" -X POST \
    -H "Content-Type: application/json" \
    -H "X-API-Key: $admin_api_key" \
    -d "$create_connection_payload" \
    "${base}/api/v1/admin/connections")"

  connection_id="$(extract_json_string_field "$create_connection_response" "connectionId")"
  if [[ -z "$connection_id" ]]; then
    log_error "Admin CRUD smoke failed: could not parse connectionId from create response"
    return 1
  fi

  publish_layer_payload="$(cat <<JSON
{"schema":"public","table":"$(json_escape "$table_name")","layerName":"$(json_escape "$layer_name")","description":"Terraform smoke test layer","geometryColumn":"geom","geometryType":"Point","srid":4326,"primaryKey":"id","fields":["id","name","population"],"serviceName":"$(json_escape "$service_name")","enabled":true}
JSON
)"

  publish_layer_response="$(curl -fsS --max-time 20 "${curl_args[@]}" -X POST \
    -H "Content-Type: application/json" \
    -H "X-API-Key: $admin_api_key" \
    -d "$publish_layer_payload" \
    "${base}/api/v1/admin/connections/${connection_id}/layers")"

  layer_id="$(extract_json_number_field "$publish_layer_response" "layerId")"
  if [[ -z "$layer_id" ]]; then
    log_error "Admin CRUD smoke failed: could not parse layerId from publish response"
    return 1
  fi

  run_db_sql_k8s "
    INSERT INTO features (layer_id, geometry, attributes)
    VALUES (
      ${layer_id},
      ST_SetSRID(ST_Point(1, 1), 4326),
      jsonb_build_object('id', 1, 'name', 'Smoke Feature', 'population', 1)
    );
  "

  query_url="${base}/rest/services/${service_name}/FeatureServer/${layer_id}/query?where=1%3D1&outFields=id,name,population&f=pjson"
  query_response="$(curl -fsS --max-time 20 "${curl_args[@]}" \
    -H "X-API-Key: $admin_api_key" \
    "$query_url")"

  if command -v jq >/dev/null 2>&1; then
    feature_count="$(printf '%s' "$query_response" | jq -r '(.features // []) | length' 2>/dev/null || echo 0)"
  else
    feature_count="$(printf '%s' "$query_response" | tr -d '\n\r' | grep -o '"attributes":' | wc -l | tr -d ' ')"
  fi

  if [[ -z "$feature_count" || "$feature_count" == "0" ]]; then
    log_error "Admin CRUD smoke failed: query returned no features"
    return 1
  fi

  log_info "Admin CRUD/query smoke passed (service=${service_name}, layerId=${layer_id}, features=${feature_count})"
}

verify_postgis_extensions() {
  local extensions

  extensions="$(kubectl -n "$NAMESPACE" exec deployment/honua-postgis -- sh -c "PGPASSWORD=honua psql -h 127.0.0.1 -U honua -d honua -tA -c \"SELECT extname FROM pg_extension WHERE extname IN ('postgis','postgis_raster') ORDER BY extname;\"" || true)"

  if [[ "$extensions" != *"postgis"* || "$extensions" != *"postgis_raster"* ]]; then
    log_error "Expected postgis + postgis_raster extensions not both present"
    log_error "Observed extensions output: ${extensions:-<none>}"
    return 1
  fi

  log_info "Verified extensions in k8s PostGIS: postgis + postgis_raster"
}

verify_db_backup_restore() {
  local extensions_count

  kubectl -n "$NAMESPACE" exec deployment/honua-postgis -- sh -c "set -e; \
    export PGPASSWORD=honua; \
    pg_dump -h 127.0.0.1 -U honua -d honua -Fc -f /tmp/honua.dump; \
    psql -h 127.0.0.1 -U honua -d postgres -c 'DROP DATABASE IF EXISTS honua_restore_check'; \
    psql -h 127.0.0.1 -U honua -d postgres -c 'CREATE DATABASE honua_restore_check'; \
    pg_restore -h 127.0.0.1 -U honua -d honua_restore_check /tmp/honua.dump;" >/dev/null

  extensions_count="$(kubectl -n "$NAMESPACE" exec deployment/honua-postgis -- sh -c "PGPASSWORD=honua psql -h 127.0.0.1 -U honua -d honua_restore_check -tA -c \"SELECT COUNT(*) FROM pg_extension WHERE extname IN ('postgis','postgis_raster');\"" | tr -d '[:space:]')"

  kubectl -n "$NAMESPACE" exec deployment/honua-postgis -- sh -c "PGPASSWORD=honua psql -h 127.0.0.1 -U honua -d postgres -c 'DROP DATABASE IF EXISTS honua_restore_check'" >/dev/null

  if [[ "$extensions_count" != "2" ]]; then
    log_error "DB backup/restore drill failed: expected 2 PostGIS extensions in restored DB, got ${extensions_count:-<none>}"
    return 1
  fi

  log_info "DB backup/restore drill passed"
}

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
  root="$TEMP_REPO_ROOT/infrastructure/terraform/examples/observability"

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
  root="$TEMP_REPO_ROOT/infrastructure/terraform/examples/observability"

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
