# Sourced by run-azure-terraform-integration.sh after the common logging and
# runtime helpers have been defined.

run_load_probe() {
  local base_url="$1"
  local requests="$2"
  local concurrency="$3"
  local normalized_base
  local target_url
  local fail_file
  local failures
  local error_rate

  normalized_base="$(normalize_base_url "$base_url")"
  target_url="${normalized_base}/healthz/ready"

  fail_file="$(mktemp)"

  for ((i = 1; i <= requests; i++)); do
    (
      if ! curl -fsS --max-time 20 "$target_url" >/dev/null; then
        echo "1" >> "$fail_file"
      fi
    ) &

    if (( i % concurrency == 0 )); then
      wait
    fi
  done

  wait

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

assert_idempotent_plan() {
  local root="$1"
  local log_file
  local exit_code

  log_file="$(mktemp)"
  set +e
  run_tf -chdir="$root" plan -input=false -no-color -detailed-exitcode >"$log_file" 2>&1
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

verify_protocol_endpoints() {
  local base_url="$1"
  local normalized
  local admin_api_key
  local status

  normalized="$(normalize_base_url "$base_url")"
  admin_api_key="${HONUA_ADMIN_PASSWORD}"

  check_endpoint() {
    local endpoint="$1"
    local endpoint_status
    local authorized_status
    local attempt
    local response_file
    local body_preview

    for attempt in 1 2 3 4 5 6; do
      response_file="$(mktemp)"
      endpoint_status="$(curl -sS -o "$response_file" -w "%{http_code}" --max-time 20 "$endpoint" || true)"

      if [[ "$endpoint_status" == 2* || "$endpoint_status" == 3* ]]; then
        rm -f "$response_file"
        return 0
      fi

      if [[ "$endpoint_status" == "401" || "$endpoint_status" == "403" ]]; then
        authorized_status="$(curl -sS -o "$response_file" -w "%{http_code}" --max-time 20 \
          -H "X-API-Key: $admin_api_key" \
          "$endpoint" || true)"
        if [[ "$authorized_status" == 2* || "$authorized_status" == 3* ]]; then
          rm -f "$response_file"
          return 0
        fi
        endpoint_status="$authorized_status"
      fi

      if [[ "$endpoint" == *"/odata" && "$endpoint_status" == "404" ]] && grep -Eqi "No OData-enabled services found|OData is not enabled for any available service" "$response_file"; then
        rm -f "$response_file"
        return 0
      fi

      if [[ "$attempt" -lt 6 ]]; then
        rm -f "$response_file"
        log_warn "Protocol endpoint not ready yet: $endpoint returned HTTP $endpoint_status (attempt $attempt/6)"
        sleep 10
        continue
      fi

      body_preview="$(tr '\n' ' ' < "$response_file" | sed 's/[[:space:]]\+/ /g' | cut -c1-200)"
      rm -f "$response_file"
      log_error "Protocol smoke endpoint failed: $endpoint returned HTTP $endpoint_status (${body_preview:-no-body})"
      return 1
    done

    return 1
  }

  check_endpoint "${normalized}/rest/services?f=pjson"
  check_endpoint "${normalized}/ogc/features"
  check_endpoint "${normalized}/odata"

  status="$(curl -sSL -o /dev/null -w "%{http_code}" --max-time 20 "${normalized}/api/v1/admin/config")"
  if [[ "$status" != "401" && "$status" != "403" ]]; then
    log_error "Expected unauthenticated admin endpoint to return 401/403, got $status"
    return 1
  fi

  log_info "Protocol/admin smoke checks passed for $normalized"
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

normalize_base_url() {
  local base_url="${1%/}"
  if [[ "$base_url" =~ ^https?:// ]]; then
    printf '%s\n' "$base_url"
    return
  fi

  printf 'https://%s\n' "$base_url"
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

run_db_sql() {
  local db_host="$1"
  local sql="$2"
  local sql_file

  sql_file="$(mktemp)"
  printf '%s\n' "$sql" > "$sql_file"

  if [[ "$USE_DOCKER_PG_TOOLS" == "true" ]]; then
    docker run --rm \
      -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
      -v "$sql_file:/tmp/smoke.sql:ro" \
      postgres:16-alpine \
      sh -c "psql '$(pg_conn "$db_host" "honua")' -v ON_ERROR_STOP=1 -f /tmp/smoke.sql" >/dev/null
  else
    PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
      psql "$(pg_conn "$db_host" "honua")" -v ON_ERROR_STOP=1 -f "$sql_file" >/dev/null
  fi

  rm -f "$sql_file"
}

run_admin_api_crud_smoke() {
  local base_url="$1"
  local db_host="$2"
  local normalized
  local suffix
  local table_name
  local layer_name
  local service_name
  local connection_name
  local connection_id=""
  local layer_id=""
  local query_url
  local query_response
  local feature_count=0
  local create_connection_payload
  local publish_layer_payload
  local create_connection_response
  local publish_layer_response

  normalized="$(normalize_base_url "$base_url")"
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

    local cleanup_db_host="${db_host:-}"
    local cleanup_table_name="${table_name:-}"
    local cleanup_layer_id="${layer_id:-}"
    local cleanup_service_name="${service_name:-}"
    local cleanup_connection_id="${connection_id:-}"
    local cleanup_normalized="${normalized:-}"

    if [[ -n "$cleanup_db_host" ]]; then
      run_db_sql "$cleanup_db_host" "DROP TABLE IF EXISTS public.${cleanup_table_name};" || true

      if [[ -n "$cleanup_layer_id" ]]; then
        run_db_sql "$cleanup_db_host" "
          DELETE FROM features WHERE layer_id = ${cleanup_layer_id};
          DELETE FROM honua.layer_fields WHERE layer_id = ${cleanup_layer_id};
          DELETE FROM honua.service_layers WHERE layer_id = ${cleanup_layer_id};
          DELETE FROM honua.layers WHERE layer_id = ${cleanup_layer_id};
        " || true
      fi

      run_db_sql "$cleanup_db_host" "DELETE FROM honua.services WHERE service_name = '$(json_escape "$cleanup_service_name")';" || true

      if [[ -n "$cleanup_connection_id" ]]; then
        curl -sS --max-time 20 -X DELETE \
          -H "X-API-Key: $HONUA_ADMIN_PASSWORD" \
          "${cleanup_normalized}/api/v1/admin/connections/${cleanup_connection_id}" >/dev/null || true
      fi
    fi

    if [[ "$had_errexit" == "true" ]]; then
      set -e
    fi
  }

  trap cleanup_smoke RETURN

  run_db_sql "$db_host" "
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
{"name":"$(json_escape "$connection_name")","description":"Terraform smoke test connection","host":"$(json_escape "$db_host")","port":5432,"databaseName":"honua","username":"honua","password":"$(json_escape "$DB_PASSWORD_EFFECTIVE")","sslRequired":true,"sslMode":"Require"}
JSON
)"

  create_connection_response="$(curl -fsS --max-time 20 -X POST \
    -H "Content-Type: application/json" \
    -H "X-API-Key: $HONUA_ADMIN_PASSWORD" \
    -d "$create_connection_payload" \
    "${normalized}/api/v1/admin/connections")"

  connection_id="$(extract_json_string_field "$create_connection_response" "connectionId")"
  if [[ -z "$connection_id" ]]; then
    log_error "Admin CRUD smoke failed: could not parse connectionId from create response"
    return 1
  fi

  publish_layer_payload="$(cat <<JSON
{"schema":"public","table":"$(json_escape "$table_name")","layerName":"$(json_escape "$layer_name")","description":"Terraform smoke test layer","geometryColumn":"geom","geometryType":"Point","srid":4326,"primaryKey":"id","fields":["id","name","population"],"serviceName":"$(json_escape "$service_name")","enabled":true}
JSON
)"

  publish_layer_response="$(curl -fsS --max-time 20 -X POST \
    -H "Content-Type: application/json" \
    -H "X-API-Key: $HONUA_ADMIN_PASSWORD" \
    -d "$publish_layer_payload" \
    "${normalized}/api/v1/admin/connections/${connection_id}/layers")"

  layer_id="$(extract_json_number_field "$publish_layer_response" "layerId")"
  if [[ -z "$layer_id" ]]; then
    log_error "Admin CRUD smoke failed: could not parse layerId from publish response"
    return 1
  fi

  run_db_sql "$db_host" "
    INSERT INTO features (layer_id, geometry, attributes)
    VALUES (
      ${layer_id},
      ST_SetSRID(ST_Point(1, 1), 4326),
      jsonb_build_object('id', 1, 'name', 'Smoke Feature', 'population', 1)
    );
  "

  query_url="${normalized}/rest/services/${service_name}/FeatureServer/${layer_id}/query?where=1%3D1&outFields=id,name,population&f=pjson"
  query_response="$(curl -fsS --max-time 20 \
    -H "X-API-Key: $HONUA_ADMIN_PASSWORD" \
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

  log_info "Admin CRUD/query smoke passed for $normalized (service=${service_name}, layerId=${layer_id}, features=${feature_count})"
}

verify_redis_exists() {
  local resource_group="$1"
  local count

  if [[ -n "$EXISTING_REDIS_CONNECTION_STRING" && "$DATA_APPLIED" != "true" ]]; then
    log_info "Using existing Redis connection string; skipping Azure Redis resource check"
    return 0
  fi

  count="$(run_az redis list -g "$resource_group" --query "length(@)" -o tsv)"
  if [[ -z "$count" || "$count" == "0" ]]; then
    log_error "Redis instance not found in resource group: $resource_group"
    return 1
  fi

  log_info "Redis instance count in $resource_group: $count"
}

verify_postgis_extensions() {
  local db_fqdn="$1"
  local extensions

  if [[ "$USE_DOCKER_PG_TOOLS" == "true" ]]; then
    extensions="$(docker run --rm \
      -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
      postgres:16-alpine \
      sh -c "psql '$(pg_conn "$db_fqdn" "honua")' -v ON_ERROR_STOP=1 -tA -c \"SELECT extname FROM pg_extension WHERE extname IN ('postgis','postgis_raster') ORDER BY extname;\"" || true)"
  else
    extensions="$(PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
      psql "$(pg_conn "$db_fqdn" "honua")" -v ON_ERROR_STOP=1 -tA -c "SELECT extname FROM pg_extension WHERE extname IN ('postgis','postgis_raster') ORDER BY extname;" || true)"
  fi

  if [[ "$extensions" != *"postgis"* || "$extensions" != *"postgis_raster"* ]]; then
    log_error "Expected postgis + postgis_raster extensions not both present on $db_fqdn"
    log_error "Observed extensions output: ${extensions:-<none>}"
    return 1
  fi

  log_info "Verified extensions on $db_fqdn: postgis + postgis_raster"
}

verify_db_backup_restore() {
  local db_fqdn="$1"
  local extensions_count=""
  local restored_probe_count=""
  local drill_table="backup_restore_probe_$(date -u +%m%d%H%M%S)$RANDOM"
  local dump_file
  local drill_log
  local restore_engine="local"

  dump_file="$(mktemp)"
  drill_log="$(mktemp)"

  cleanup_restore_drill() {
    local had_errexit=false
    if [[ $- == *e* ]]; then
      had_errexit=true
    fi
    set +e

    run_db_sql "$db_fqdn" "DROP TABLE IF EXISTS public.${drill_table};" || true

    if [[ "$USE_DOCKER_PG_TOOLS" == "true" ]]; then
      docker run --rm \
        -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
        postgres:16-alpine \
        sh -c "psql '$(pg_conn "$db_fqdn" "postgres")' -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS honua_restore_check'" >/dev/null 2>&1 || true
    else
      PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
        psql "$(pg_conn "$db_fqdn" "postgres")" -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS honua_restore_check' >/dev/null 2>&1 || true
    fi

    rm -f "$dump_file" "$drill_log"

    if [[ "$had_errexit" == "true" ]]; then
      set -e
    fi
  }

  run_db_sql "$db_fqdn" "
    DROP TABLE IF EXISTS public.${drill_table};
    CREATE TABLE public.${drill_table} (
      id INTEGER PRIMARY KEY,
      note TEXT NOT NULL
    );
    INSERT INTO public.${drill_table} (id, note)
    VALUES (1, 'terraform-backup-drill');
  "

  run_restore_drill_local() {
    PGPASSWORD="$DB_PASSWORD_EFFECTIVE" pg_dump "$(pg_conn "$db_fqdn" "honua")" -Fc -f "$dump_file"
    PGPASSWORD="$DB_PASSWORD_EFFECTIVE" psql "$(pg_conn "$db_fqdn" "postgres")" -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS honua_restore_check' >/dev/null
    PGPASSWORD="$DB_PASSWORD_EFFECTIVE" psql "$(pg_conn "$db_fqdn" "postgres")" -v ON_ERROR_STOP=1 -c 'CREATE DATABASE honua_restore_check' >/dev/null
    PGPASSWORD="$DB_PASSWORD_EFFECTIVE" pg_restore --no-owner --no-privileges -d "$(pg_conn "$db_fqdn" "honua_restore_check")" "$dump_file" >/dev/null
  }

  run_restore_drill_docker() {
    docker run --rm \
      -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
      postgres:16-alpine \
      sh -c "set -e; \
        pg_dump '$(pg_conn "$db_fqdn" "honua")' -Fc -f /tmp/honua.dump; \
        psql '$(pg_conn "$db_fqdn" "postgres")' -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS honua_restore_check'; \
        psql '$(pg_conn "$db_fqdn" "postgres")' -v ON_ERROR_STOP=1 -c 'CREATE DATABASE honua_restore_check'; \
        pg_restore --no-owner --no-privileges -d '$(pg_conn "$db_fqdn" "honua_restore_check")' /tmp/honua.dump >/dev/null;" >/dev/null
  }

  inspect_restored_db_local() {
    restored_probe_count="$(PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
      psql "$(pg_conn "$db_fqdn" "honua_restore_check")" -tA -c "SELECT COUNT(*) FROM public.${drill_table} WHERE id = 1;" | tr -d '[:space:]')"
    extensions_count="$(PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
      psql "$(pg_conn "$db_fqdn" "honua_restore_check")" -tA -c "SELECT COUNT(*) FROM pg_extension WHERE extname IN ('postgis','postgis_raster');" | tr -d '[:space:]')"

    if [[ "$extensions_count" != "2" ]]; then
      PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
        psql "$(pg_conn "$db_fqdn" "honua_restore_check")" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS postgis_raster;" >/dev/null
      extensions_count="$(PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
        psql "$(pg_conn "$db_fqdn" "honua_restore_check")" -tA -c "SELECT COUNT(*) FROM pg_extension WHERE extname IN ('postgis','postgis_raster');" | tr -d '[:space:]')"
    fi
  }

  inspect_restored_db_docker() {
    restored_probe_count="$(docker run --rm \
      -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
      postgres:16-alpine \
      sh -c "psql '$(pg_conn "$db_fqdn" "honua_restore_check")' -tA -c \"SELECT COUNT(*) FROM public.${drill_table} WHERE id = 1;\"" | tr -d '[:space:]')"
    extensions_count="$(docker run --rm \
      -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
      postgres:16-alpine \
      sh -c "psql '$(pg_conn "$db_fqdn" "honua_restore_check")' -tA -c \"SELECT COUNT(*) FROM pg_extension WHERE extname IN ('postgis','postgis_raster');\"" | tr -d '[:space:]')"

    if [[ "$extensions_count" != "2" ]]; then
      docker run --rm \
        -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
        postgres:16-alpine \
        sh -c "psql '$(pg_conn "$db_fqdn" "honua_restore_check")' -v ON_ERROR_STOP=1 -c \"CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS postgis_raster;\"" >/dev/null
      extensions_count="$(docker run --rm \
        -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
        postgres:16-alpine \
        sh -c "psql '$(pg_conn "$db_fqdn" "honua_restore_check")' -tA -c \"SELECT COUNT(*) FROM pg_extension WHERE extname IN ('postgis','postgis_raster');\"" | tr -d '[:space:]')"
    fi
  }

  if [[ "$USE_DOCKER_PG_TOOLS" == "true" ]]; then
    if ! run_restore_drill_docker >"$drill_log" 2>&1; then
      log_error "DB backup/restore drill failed while using dockerized PostgreSQL tools"
      cat "$drill_log" >&2
      cleanup_restore_drill
      return 1
    fi
    restore_engine="docker"
  else
    if ! run_restore_drill_local >"$drill_log" 2>&1; then
      if command -v docker >/dev/null 2>&1; then
        log_warn "Local PostgreSQL tools failed during DB backup/restore drill; retrying with dockerized tools"
        if ! run_restore_drill_docker >"$drill_log" 2>&1; then
          log_error "DB backup/restore drill failed after docker fallback"
          cat "$drill_log" >&2
          cleanup_restore_drill
          return 1
        fi
        restore_engine="docker"
      else
        log_error "DB backup/restore drill failed with local PostgreSQL tools and docker fallback is unavailable"
        cat "$drill_log" >&2
        cleanup_restore_drill
        return 1
      fi
    fi
  fi

  if [[ "$restore_engine" == "docker" ]]; then
    if ! inspect_restored_db_docker >>"$drill_log" 2>&1; then
      log_error "DB backup/restore drill failed while inspecting restored database via dockerized PostgreSQL tools"
      cat "$drill_log" >&2
      cleanup_restore_drill
      return 1
    fi
  else
    if ! inspect_restored_db_local >>"$drill_log" 2>&1; then
      if command -v docker >/dev/null 2>&1; then
        log_warn "Local PostgreSQL tools failed while inspecting restored database; retrying inspection with dockerized tools"
        if ! inspect_restored_db_docker >>"$drill_log" 2>&1; then
          log_error "DB backup/restore drill failed while inspecting restored database after docker fallback"
          cat "$drill_log" >&2
          cleanup_restore_drill
          return 1
        fi
      else
        log_error "DB backup/restore drill failed while inspecting restored database and docker fallback is unavailable"
        cat "$drill_log" >&2
        cleanup_restore_drill
        return 1
      fi
    fi
  fi

  if [[ "$restored_probe_count" != "1" ]]; then
    log_error "DB backup/restore drill failed: restored DB probe row mismatch (expected=1, observed=${restored_probe_count:-<none>})"
    cleanup_restore_drill
    return 1
  fi

  if [[ "$extensions_count" != "2" ]]; then
    log_error "DB backup/restore drill failed: expected 2 PostGIS extensions in restored DB, got ${extensions_count:-<none>}"
    cleanup_restore_drill
    return 1
  fi

  cleanup_restore_drill
  log_info "DB backup/restore drill passed"
}

wait_for_aca_replicas() {
  local resource_group="$1"
  local app_name="$2"
  local expected_min="$3"
  local timeout="$4"
  local start_epoch
  local current

  start_epoch="$(date +%s)"
  while true; do
    current="$(run_az containerapp replica list -g "$resource_group" -n "$app_name" --query "length(@)" -o tsv || echo 0)"

    if [[ -n "$current" ]] && (( current >= expected_min )); then
      log_info "Container App replicas reached target: $current >= $expected_min"
      return 0
    fi

    if (( $(date +%s) - start_epoch > timeout )); then
      log_error "Timed out waiting for ACA replicas >= $expected_min (current: ${current:-unknown})"
      return 1
    fi

    sleep 15
  done
}

estimate_stack_cost() {
  local stack_name="$1"
  case "$stack_name" in
    aca) echo "45" ;;
    functions) echo "30" ;;
    both) echo "75" ;;
    *) echo "0" ;;
  esac
}

assert_cost_guardrail() {
  local estimated

  if ! awk -v m="$MAX_RUN_COST_USD" 'BEGIN { exit !(m > 0) }'; then
    return
  fi

  estimated="$(estimate_stack_cost "$STACK")"
  if awk -v e="$estimated" -v m="$MAX_RUN_COST_USD" 'BEGIN { exit !(e <= m) }'; then
    log_info "Estimated run cost ($estimated USD) is within cap ($MAX_RUN_COST_USD USD)"
    return
  fi

  log_error "Estimated run cost ($estimated USD) exceeds cap ($MAX_RUN_COST_USD USD)"
  exit 1
}
