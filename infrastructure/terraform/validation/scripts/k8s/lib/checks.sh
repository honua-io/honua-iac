# Sourced by validation.sh after common helpers are defined.

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

  endpoint_status_with_retry() {
    local endpoint="$1"
    local attempt
    local endpoint_status=""

    for attempt in $(seq 1 12); do
      endpoint_status="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 20 "${curl_args[@]}" "$endpoint" || true)"
      case "$endpoint_status" in
        000|502|503|504)
          if [[ "$attempt" -lt 12 ]]; then
            log_info "Endpoint ${endpoint} returned transient HTTP ${endpoint_status}; retrying warmup probe (${attempt}/12)"
            sleep 5
            continue
          fi
          ;;
      esac

      printf '%s' "$endpoint_status"
      return 0
    done

    printf '%s' "$endpoint_status"
  }

  check_endpoint() {
    local endpoint="$1"
    local endpoint_status

    endpoint_status="$(endpoint_status_with_retry "$endpoint")"
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

    endpoint_status="$(endpoint_status_with_retry "$endpoint")"
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

  status="$(endpoint_status_with_retry "${base}/api/v1/admin/config")"
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
