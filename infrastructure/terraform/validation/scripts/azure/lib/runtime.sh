# Sourced by run-azure-terraform-integration.sh after the common logging and
# command helpers have been defined.

build_tf_image_if_needed() {
  if docker image inspect "$TF_IMAGE" >/dev/null 2>&1; then
    return
  fi

  log_info "Building Terraform image with psql client: $TF_IMAGE"
  docker build -t "$TF_IMAGE" - <<'DOCKERFILE'
FROM hashicorp/terraform:1.8.5
RUN apk add --no-cache postgresql-client
DOCKERFILE
}

configure_runtime_tools() {
  if command -v terraform >/dev/null 2>&1; then
    USE_DOCKER_TF=false
  else
    require_command docker
    build_tf_image_if_needed
    USE_DOCKER_TF=true
  fi

  if command -v az >/dev/null 2>&1; then
    USE_DOCKER_AZ_CLI=false
    export AZURE_CONFIG_DIR="${AZURE_CONFIG_DIR:-$AZ_CONFIG_DIR_DEFAULT}"
    mkdir -p "$AZURE_CONFIG_DIR"
  else
    require_command docker
    USE_DOCKER_AZ_CLI=true
  fi

  if command -v psql >/dev/null 2>&1 && command -v pg_dump >/dev/null 2>&1 && command -v pg_restore >/dev/null 2>&1; then
    USE_DOCKER_PG_TOOLS=false
  else
    require_command docker
    USE_DOCKER_PG_TOOLS=true
  fi

  log_info "Terraform executor: $([[ "$USE_DOCKER_TF" == "true" ]] && echo docker || echo local)"
  log_info "Azure CLI executor: $([[ "$USE_DOCKER_AZ_CLI" == "true" ]] && echo docker || echo local)"
  log_info "Postgres tools executor: $([[ "$USE_DOCKER_PG_TOOLS" == "true" ]] && echo docker || echo local)"
}

prepare_tf_workspace() {
  TEMP_TF_ROOT="$(mktemp -d)"
  cp -R "$REPO_ROOT/infrastructure/terraform" "$TEMP_TF_ROOT/terraform"
}

run_tf() {
  if [[ "$USE_DOCKER_TF" == "true" ]]; then
    docker run --rm \
      -e ARM_CLIENT_ID \
      -e ARM_CLIENT_SECRET \
      -e ARM_TENANT_ID \
      -e ARM_SUBSCRIPTION_ID \
      -e TF_VAR_location \
      -e TF_VAR_environment \
      -e TF_VAR_name_prefix \
      -e TF_VAR_honua_admin_password \
      -e TF_VAR_honua_connection_encryption_master_key \
      -e TF_VAR_db_admin_password \
      -e TF_VAR_db_sku_name \
      -e TF_VAR_db_storage_mb \
      -e TF_VAR_db_geo_redundant_backup_enabled \
      -e TF_VAR_db_backup_retention_days \
      -e TF_VAR_db_public_network_access \
      -e TF_VAR_honua_image \
      -e TF_VAR_enable_postgis \
      -e TF_VAR_redis_enabled \
      -e TF_VAR_redis_sku_name \
      -e TF_VAR_redis_family \
      -e TF_VAR_redis_capacity \
      -e TF_VAR_redis_public_network_access_enabled \
      -e TF_VAR_redis_connection_string \
      -e TF_VAR_existing_db_fqdn \
      -e TF_VAR_existing_db_connection_string \
      -e TF_VAR_db_firewall_start_ip \
      -e TF_VAR_db_firewall_end_ip \
      -e TF_VAR_registry_server \
      -e TF_VAR_registry_username \
      -e TF_VAR_registry_password \
      -e TF_VAR_min_replicas \
      -e TF_VAR_max_replicas \
      -e TF_VAR_key_vault_default_action \
      -e TF_VAR_plan_sku_name \
      -e TF_VAR_skip_migrations \
      -e TF_VAR_tags \
      -e TF_IN_AUTOMATION=true \
      -v "$TEMP_TF_ROOT/terraform:/workspace" \
      -w /workspace \
      "$TF_IMAGE" "$@"
    return
  fi

  (
    cd "$TEMP_TF_ROOT/terraform"
    TF_IN_AUTOMATION=true terraform "$@"
  )
}

run_az() {
  if [[ "$USE_DOCKER_AZ_CLI" == "true" ]]; then
    docker run --rm \
      -e ARM_CLIENT_ID \
      -e ARM_CLIENT_SECRET \
      -e ARM_TENANT_ID \
      -e ARM_SUBSCRIPTION_ID \
      -e AZ_LOGIN_MAX_ATTEMPTS \
      -e AZ_LOGIN_RETRY_SECONDS \
      -e AZURE_CORE_ONLY_SHOW_ERRORS=true \
      "$AZ_CLI_IMAGE" \
      sh -c '
        set -e
        az config set extension.use_dynamic_install=yes_without_prompt >/dev/null
        for attempt in $(seq 1 "$AZ_LOGIN_MAX_ATTEMPTS"); do
          if az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID" >/dev/null 2>&1 && \
             az account set -s "$ARM_SUBSCRIPTION_ID" >/dev/null 2>&1 && \
             az account show --query id -o tsv >/dev/null 2>&1; then
            az "$@"
            exit 0
          fi
          sleep "$AZ_LOGIN_RETRY_SECONDS"
        done
        echo "[ERROR] Azure CLI login retry budget exhausted for service principal" >&2
        exit 1
      ' \
      sh "$@"
    return
  fi

  ensure_local_az_session() {
    if [[ "$AZ_SESSION_INITIALIZED" == "true" ]] && \
       [[ "$AZ_SESSION_CLIENT_ID" == "$ARM_CLIENT_ID" ]] && \
       [[ "$AZ_SESSION_TENANT_ID" == "$ARM_TENANT_ID" ]] && \
       [[ "$AZ_SESSION_SUBSCRIPTION_ID" == "$ARM_SUBSCRIPTION_ID" ]] && \
       AZURE_CORE_ONLY_SHOW_ERRORS=true az account show --query id -o tsv >/dev/null 2>&1; then
      return 0
    fi

    AZ_SESSION_INITIALIZED=false
    AZ_SESSION_CLIENT_ID=""
    AZ_SESSION_TENANT_ID=""
    AZ_SESSION_SUBSCRIPTION_ID=""
    AZURE_CORE_ONLY_SHOW_ERRORS=true az config set extension.use_dynamic_install=yes_without_prompt >/dev/null
    local attempt
    local login_succeeded=false

    for attempt in $(seq 1 "$AZ_LOGIN_MAX_ATTEMPTS"); do
      if AZURE_CORE_ONLY_SHOW_ERRORS=true az login --service-principal -u "$ARM_CLIENT_ID" -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID" >/dev/null 2>&1 && \
         AZURE_CORE_ONLY_SHOW_ERRORS=true az account set -s "$ARM_SUBSCRIPTION_ID" >/dev/null 2>&1 && \
         AZURE_CORE_ONLY_SHOW_ERRORS=true az account show --query id -o tsv >/dev/null 2>&1; then
        login_succeeded=true
        break
      fi

      if (( attempt < AZ_LOGIN_MAX_ATTEMPTS )); then
        log_warn "Azure CLI login/subscription assignment not ready yet; retrying in ${AZ_LOGIN_RETRY_SECONDS}s (attempt ${attempt}/${AZ_LOGIN_MAX_ATTEMPTS})"
        sleep "$AZ_LOGIN_RETRY_SECONDS"
      fi
    done

    if [[ "$login_succeeded" != "true" ]]; then
      log_error "Azure CLI login retry budget exhausted for service principal/subscription assignment"
      exit 1
    fi

    AZ_SESSION_INITIALIZED=true
    AZ_SESSION_CLIENT_ID="$ARM_CLIENT_ID"
    AZ_SESSION_TENANT_ID="$ARM_TENANT_ID"
    AZ_SESSION_SUBSCRIPTION_ID="$ARM_SUBSCRIPTION_ID"
  }

  ensure_local_az_session
  AZURE_CORE_ONLY_SHOW_ERRORS=true az "$@"
}

create_postgres_firewall_rule_with_retry() {
  local resource_group="$1"
  local server_name="$2"
  local rule_name="$3"
  local start_ip="$4"
  local end_ip="$5"
  local rule_context="$6"
  local max_attempts="${HONUA_AZURE_FIREWALL_RULE_MAX_ATTEMPTS:-6}"
  local retry_seconds="${HONUA_AZURE_FIREWALL_RULE_RETRY_SECONDS:-10}"
  local attempt
  local output=""
  local flattened_output=""

  for attempt in $(seq 1 "$max_attempts"); do
    if output="$(
      run_az postgres flexible-server firewall-rule create \
        --resource-group "$resource_group" \
        --name "$server_name" \
        --rule-name "$rule_name" \
        --start-ip-address "$start_ip" \
        --end-ip-address "$end_ip" \
        -o none 2>&1
    )"; then
      return 0
    fi

    if run_az postgres flexible-server firewall-rule show \
      --resource-group "$resource_group" \
      --name "$server_name" \
      --rule-name "$rule_name" \
      --query "name" \
      -o tsv >/dev/null 2>&1; then
      log_warn "Firewall rule '$rule_name' for ${rule_context} is already present after a failed create attempt; continuing"
      return 0
    fi

    flattened_output="$(printf '%s' "$output" | tr '\n' ' ' | sed 's/[[:space:]]\\+/ /g')"
    if (( attempt < max_attempts )); then
      log_warn "Retrying PostgreSQL firewall rule '$rule_name' for ${rule_context} in ${retry_seconds}s (attempt ${attempt}/${max_attempts}): ${flattened_output}"
      sleep "$retry_seconds"
      continue
    fi

    log_error "Failed to create PostgreSQL firewall rule '$rule_name' for ${rule_context} after ${max_attempts} attempts"
    printf '%s\n' "$output" >&2
    return 1
  done
}

pg_conn() {
  local db_host="$1"
  local db_name="$2"
  printf "host=%s port=5432 dbname=%s user=honua sslmode=require" "$db_host" "$db_name"
}

parse_plan_destroy_count() {
  local plan_txt="$1"
  local summary

  summary="$(grep -E '^Plan: ' "$plan_txt" | tail -1 || true)"
  if [[ -z "$summary" ]]; then
    echo "0"
    return
  fi

  echo "$summary" | sed -n 's/.*Plan: [0-9][0-9]* to add, [0-9][0-9]* to change, \([0-9][0-9]*\) to destroy.*/\1/p'
}

analyze_plan() {
  local root="$1"
  local plan_file="$2"
  local label="$3"
  local artifacts_path
  local plan_txt
  local destroy_count

  artifacts_path="${PLAN_ARTIFACT_DIR%/}"
  if [[ -n "$artifacts_path" ]]; then
    mkdir -p "$artifacts_path"
  fi

  plan_txt="$(mktemp)"
  run_tf -chdir="$root" show -no-color "$plan_file" > "$plan_txt"

  destroy_count="$(parse_plan_destroy_count "$plan_txt")"
  destroy_count="${destroy_count:-0}"

  if [[ -n "$artifacts_path" ]]; then
    cp "$TEMP_TF_ROOT/terraform/$root/$plan_file" "$artifacts_path/${label}.tfplan"
    cp "$plan_txt" "$artifacts_path/${label}.plan.txt"
  fi

  rm -f "$plan_txt"

  if [[ "$ALLOW_DESTROY_PLAN" != "true" ]] && [[ "$destroy_count" =~ ^[0-9]+$ ]] && (( destroy_count > 0 )); then
    log_error "Plan '$label' includes $destroy_count destroy actions; refusing apply without --allow-destroy-plan"
    return 1
  fi
}

plan_apply() {
  local root="$1"
  local plan_file="$2"
  local label="$3"

  run_tf -chdir="$root" plan -input=false -no-color -out="$plan_file"
  analyze_plan "$root" "$plan_file" "$label"
  run_tf_apply_with_token_retry "$root" "$plan_file"
}

run_tf_apply_with_token_retry() {
  local root="$1"
  local plan_file="$2"
  local attempt
  local apply_log
  local exit_code

  for attempt in 1 2; do
    apply_log="$(mktemp)"

    set +e
    run_tf -chdir="$root" apply -input=false -auto-approve -no-color "$plan_file" 2>&1 | tee "$apply_log"
    exit_code=${PIPESTATUS[0]}
    set -e

    if [[ "$exit_code" -eq 0 ]]; then
      rm -f "$apply_log"
      return 0
    fi

    if grep -q "ExpiredAuthenticationToken" "$apply_log" && [[ "$attempt" -lt 2 ]]; then
      log_warn "Terraform apply failed with ExpiredAuthenticationToken; retrying apply once"
      rm -f "$apply_log"
      continue
    fi

    rm -f "$apply_log"
    return "$exit_code"
  done
}
