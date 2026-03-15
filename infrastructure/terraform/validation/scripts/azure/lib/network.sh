# Sourced by run-azure-terraform-integration.sh after the common logging,
# runtime, and verification helpers have been defined.

wait_for_ready() {
  local base_url="$1"
  local timeout="$2"
  local normalized_base
  local ready_url
  local start_epoch
  local elapsed

  normalized_base="$(normalize_base_url "$base_url")"
  ready_url="${normalized_base}/healthz/ready"

  start_epoch="$(date +%s)"
  while true; do
    if curl -fsSL --max-time 20 "$ready_url" >/dev/null; then
      elapsed=$(( $(date +%s) - start_epoch ))
      if (( elapsed > READY_SLO_SECONDS )); then
        log_error "Ready SLO failed: ${elapsed}s exceeds ${READY_SLO_SECONDS}s ($ready_url)"
        return 1
      fi
      log_info "Ready check passed in ${elapsed}s: $ready_url"
      return 0
    fi

    if (( $(date +%s) - start_epoch > timeout )); then
      log_error "Timed out waiting for readiness: $ready_url"
      return 1
    fi

    sleep 10
  done
}

ensure_aca_db_firewall_access() {
  local resource_group="$1"
  local app_name="$2"
  local db_fqdn="$3"
  local postgres_resource_group=""
  local server_name
  local outbound_ips
  local index=0
  local rule_name

  if [[ -z "$resource_group" || -z "$app_name" || -z "$db_fqdn" ]]; then
    return 0
  fi

  if [[ "$db_fqdn" != *.postgres.database.azure.com ]]; then
    return 0
  fi

  server_name="${db_fqdn%%.*}"
  postgres_resource_group="$(resolve_postgres_resource_group "$server_name")"

  if [[ -z "$postgres_resource_group" ]]; then
    log_warn "Could not determine PostgreSQL resource group for $server_name; skipping ACA DB firewall access"
    return 0
  fi

  outbound_ips="$(run_az containerapp show \
    --resource-group "$resource_group" \
    --name "$app_name" \
    --query "properties.outboundIpAddresses[]" \
    -o tsv || true)"

  if [[ -z "$outbound_ips" ]]; then
    log_warn "ACA outbound IP discovery returned no values for $resource_group/$app_name"
    return 0
  fi

  while IFS= read -r ip; do
    if [[ -z "$ip" ]]; then
      continue
    fi

    rule_name="aca-validation-egress-$index"
    log_info "Allowing ACA outbound IP $ip to reach PostgreSQL server $server_name"
    create_postgres_firewall_rule_with_retry \
      "$postgres_resource_group" \
      "$server_name" \
      "$rule_name" \
      "$ip" \
      "$ip" \
      "ACA outbound IP $ip"

    ACA_DB_FIREWALL_RULES+=("${postgres_resource_group}|${server_name}|${rule_name}")
    index=$((index + 1))
  done <<< "$outbound_ips"
}

ensure_functions_db_firewall_access() {
  local resource_group="$1"
  local app_name="$2"
  local db_fqdn="$3"
  local postgres_resource_group=""
  local server_name
  local outbound_ips=""
  local index=0
  local rule_name
  local ip
  local max_attempts="${HONUA_AZURE_FUNCTIONAPP_LOOKUP_MAX_ATTEMPTS:-12}"
  local retry_seconds="${HONUA_AZURE_FUNCTIONAPP_LOOKUP_RETRY_SECONDS:-10}"
  local attempt

  if [[ -z "$resource_group" || -z "$app_name" || -z "$db_fqdn" ]]; then
    return 0
  fi

  if [[ "$db_fqdn" != *.postgres.database.azure.com ]]; then
    return 0
  fi

  server_name="${db_fqdn%%.*}"
  postgres_resource_group="$(resolve_postgres_resource_group "$server_name")"

  if [[ -z "$postgres_resource_group" ]]; then
    log_warn "Could not determine PostgreSQL resource group for $server_name; skipping Functions DB firewall access"
    return 0
  fi

  # Azure Functions Premium/Consumption plans do not expose a stable, definitive
  # outbound IP allowlist for PostgreSQL firewalling. Use the temporary
  # Azure-services rule for validation runs so readiness is not blocked on an
  # empty or stale outbound IP set.
  case "$FUNCTIONS_PLAN_SKU" in
    EP*|Y1)
      rule_name="functions-validation-azure-services"
      log_warn "Functions plan '$FUNCTIONS_PLAN_SKU' uses shared/dynamic outbound IPs; allowing Azure services to reach PostgreSQL server $server_name for this validation run"
      create_postgres_firewall_rule_with_retry \
        "$postgres_resource_group" \
        "$server_name" \
        "$rule_name" \
        "0.0.0.0" \
        "0.0.0.0" \
        "Functions Azure-services fallback"

      FUNCTIONS_DB_FIREWALL_RULES+=("${postgres_resource_group}|${server_name}|${rule_name}")
      return 0
      ;;
  esac

  for attempt in $(seq 1 "$max_attempts"); do
    outbound_ips="$(
      {
        run_az functionapp show \
          --resource-group "$resource_group" \
          --name "$app_name" \
          --query "outboundIpAddresses" \
          -o tsv 2>/dev/null || true
        printf '\n'
        run_az functionapp show \
          --resource-group "$resource_group" \
          --name "$app_name" \
          --query "possibleOutboundIpAddresses" \
          -o tsv 2>/dev/null || true
      } | tr ',;' '\n' | awk 'NF && !seen[$0]++'
    )"

    if [[ -n "$outbound_ips" ]]; then
      break
    fi

    if (( attempt < max_attempts )); then
      log_warn "Functions outbound IP discovery not ready yet for ${resource_group}/${app_name}; retrying in ${retry_seconds}s (attempt ${attempt}/${max_attempts})"
      sleep "$retry_seconds"
    fi
  done

  if [[ -z "$outbound_ips" ]]; then
    rule_name="functions-validation-azure-services"
    log_warn "Functions outbound IP discovery returned no values for $resource_group/$app_name; falling back to a temporary Azure-services PostgreSQL firewall rule"
    create_postgres_firewall_rule_with_retry \
      "$postgres_resource_group" \
      "$server_name" \
      "$rule_name" \
      "0.0.0.0" \
      "0.0.0.0" \
      "Functions outbound IP fallback"

    FUNCTIONS_DB_FIREWALL_RULES+=("${postgres_resource_group}|${server_name}|${rule_name}")
    return 0
  fi

  while IFS= read -r ip; do
    if [[ -z "$ip" ]]; then
      continue
    fi

    rule_name="functions-validation-egress-$index"
    log_info "Allowing Functions outbound IP $ip to reach PostgreSQL server $server_name"
    create_postgres_firewall_rule_with_retry \
      "$postgres_resource_group" \
      "$server_name" \
      "$rule_name" \
      "$ip" \
      "$ip" \
      "Functions outbound IP $ip"

    FUNCTIONS_DB_FIREWALL_RULES+=("${postgres_resource_group}|${server_name}|${rule_name}")
    index=$((index + 1))
  done <<< "$outbound_ips"
}

diagnose_aca_failure() {
  local resource_group="$1"
  local app_name="$2"

  if [[ -z "$resource_group" || -z "$app_name" ]]; then
    return 0
  fi

  log_warn "ACA readiness failed; dumping revision state for ${resource_group}/${app_name}"
  run_az containerapp revision list \
    --resource-group "$resource_group" \
    --name "$app_name" \
    --query "[].{name:name,state:properties.runningState,details:properties.runningStateDetails,health:properties.healthState,replicas:properties.replicas}" \
    -o table || true

  run_az containerapp replica list \
    --resource-group "$resource_group" \
    --name "$app_name" \
    --query "[].{name:name,state:properties.runningStateDetails,ready:properties.containers[0].ready,restarts:properties.containers[0].restartCount}" \
    -o table || true
}

diagnose_functions_failure() {
  local resource_group="$1"
  local app_name="$2"

  if [[ -z "$resource_group" || -z "$app_name" ]]; then
    return 0
  fi

  log_warn "Functions readiness failed; dumping app/container state for ${resource_group}/${app_name}"
  run_az functionapp show \
    --resource-group "$resource_group" \
    --name "$app_name" \
    --query "{name:name,state:state,host:defaultHostName,kind:kind,reserved:reserved,enabled:enabled}" \
    -o table || true

  run_az functionapp config show \
    --resource-group "$resource_group" \
    --name "$app_name" \
    --query "{linuxFxVersion:linuxFxVersion,healthCheckPath:healthCheckPath,alwaysOn:alwaysOn,acrUseManagedIdentityCreds:acrUseManagedIdentityCreds}" \
    -o table || true

  run_az functionapp config appsettings list \
    --resource-group "$resource_group" \
    --name "$app_name" \
    --query "[?name=='FUNCTIONS_WORKER_RUNTIME' || name=='FUNCTIONS_CUSTOMHANDLER_PORT' || name=='WEBSITES_ENABLE_APP_SERVICE_STORAGE' || name=='AzureWebJobsScriptRoot' || name=='AzureWebJobsStorage' || name=='ConnectionStrings__DefaultConnection' || name=='ConnectionStrings__redis'].[name,value]" \
    -o table || true
}

clear_aca_db_firewall_access() {
  local entry
  local resource_group
  local server_name
  local rule_name

  if [[ "${#ACA_DB_FIREWALL_RULES[@]}" -eq 0 ]]; then
    return 0
  fi

  for entry in "${ACA_DB_FIREWALL_RULES[@]}"; do
    resource_group="${entry%%|*}"
    entry="${entry#*|}"
    server_name="${entry%%|*}"
    rule_name="${entry##*|}"

    run_az postgres flexible-server firewall-rule delete \
      --resource-group "$resource_group" \
      --name "$server_name" \
      --rule-name "$rule_name" \
      --yes >/dev/null || true
  done
}

clear_functions_db_firewall_access() {
  local entry
  local resource_group
  local server_name
  local rule_name

  if [[ "${#FUNCTIONS_DB_FIREWALL_RULES[@]}" -eq 0 ]]; then
    return 0
  fi

  for entry in "${FUNCTIONS_DB_FIREWALL_RULES[@]}"; do
    resource_group="${entry%%|*}"
    entry="${entry#*|}"
    server_name="${entry%%|*}"
    rule_name="${entry##*|}"

    run_az postgres flexible-server firewall-rule delete \
      --resource-group "$resource_group" \
      --name "$server_name" \
      --rule-name "$rule_name" \
      --yes >/dev/null || true
  done
}

ensure_existing_db_firewall_access() {
  local postgres_resource_group=""
  local server_name=""
  local rule_name=""
  local sanitized_run_id=""

  if [[ -z "$EXISTING_DB_FQDN" || -z "$DB_FIREWALL_START_IP" || -z "$DB_FIREWALL_END_IP" ]]; then
    return 0
  fi

  if [[ "$EXISTING_DB_FQDN" != *.postgres.database.azure.com ]]; then
    return 0
  fi

  server_name="${EXISTING_DB_FQDN%%.*}"
  postgres_resource_group="$(resolve_postgres_resource_group "$server_name")"

  if [[ -z "$postgres_resource_group" ]]; then
    log_warn "Could not determine PostgreSQL resource group for reused DB $server_name; skipping runner DB firewall access"
    return 0
  fi

  sanitized_run_id="$(printf '%s' "$VALIDATION_RUN_ID" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
  rule_name="runner-${sanitized_run_id:0:52}"

  log_info "Allowing runner firewall range $DB_FIREWALL_START_IP - $DB_FIREWALL_END_IP to reach PostgreSQL server $server_name"
  create_postgres_firewall_rule_with_retry \
    "$postgres_resource_group" \
    "$server_name" \
    "$rule_name" \
    "$DB_FIREWALL_START_IP" \
    "$DB_FIREWALL_END_IP" \
    "runner firewall range ${DB_FIREWALL_START_IP}-${DB_FIREWALL_END_IP}"

  EXISTING_DB_FIREWALL_RULES+=("${postgres_resource_group}|${server_name}|${rule_name}")
}

resolve_postgres_resource_group() {
  local server_name="$1"
  local resolved=""

  if [[ -z "$server_name" ]]; then
    return 0
  fi

  resolved="$(run_az resource list \
    --name "$server_name" \
    --resource-type "Microsoft.DBforPostgreSQL/flexibleServers" \
    --query "[0].resourceGroup" \
    -o tsv || true)"

  if [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi

  if [[ -n "$EXISTING_DB_RESOURCE_GROUP" ]] && run_az postgres flexible-server show \
    --resource-group "$EXISTING_DB_RESOURCE_GROUP" \
    --name "$server_name" \
    --query "name" \
    -o tsv >/dev/null 2>&1; then
    printf '%s\n' "$EXISTING_DB_RESOURCE_GROUP"
    return 0
  fi

  if [[ -n "$DATA_RESOURCE_GROUP" ]] && run_az postgres flexible-server show \
    --resource-group "$DATA_RESOURCE_GROUP" \
    --name "$server_name" \
    --query "name" \
    -o tsv >/dev/null 2>&1; then
    printf '%s\n' "$DATA_RESOURCE_GROUP"
  fi
}

clear_existing_db_firewall_access() {
  local entry
  local resource_group
  local server_name
  local rule_name

  if [[ "${#EXISTING_DB_FIREWALL_RULES[@]}" -eq 0 ]]; then
    return 0
  fi

  for entry in "${EXISTING_DB_FIREWALL_RULES[@]}"; do
    resource_group="${entry%%|*}"
    entry="${entry#*|}"
    server_name="${entry%%|*}"
    rule_name="${entry##*|}"

    run_az postgres flexible-server firewall-rule delete \
      --resource-group "$resource_group" \
      --name "$server_name" \
      --rule-name "$rule_name" \
      --yes >/dev/null || true
  done
}
