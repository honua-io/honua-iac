# Sourced by run-azure-terraform-integration.sh after the common logging,
# runtime, network, verification, and stack helpers have been defined.

run_quota_preflight() {
  local usage_json
  local current
  local limit
  local required

  if [[ "$RUN_QUOTA_PREFLIGHT" != "true" ]]; then
    return
  fi

  cleanup_expired_validation_resource_groups

  usage_json="$(run_az vm list-usage -l "$LOCATION" --query "[?name.value=='cores'] | [0]" -o json)"
  current="$(echo "$usage_json" | sed -n 's/.*"currentValue":\([0-9][0-9]*\).*/\1/p')"
  limit="$(echo "$usage_json" | sed -n 's/.*"limit":\([0-9][0-9]*\).*/\1/p')"

  required=0
  if [[ "$STACK" == "aca" || "$STACK" == "both" ]]; then
    required=$((required + 4))
  fi
  if [[ "$STACK" == "functions" || "$STACK" == "both" ]]; then
    required=$((required + 2))
  fi

  if [[ -n "$current" && -n "$limit" ]] && (( current + required > limit )); then
    log_error "Azure quota preflight failed: cores usage $current/$limit, estimated required +$required"
    exit 1
  fi

  log_info "Azure quota preflight passed (cores current=${current:-unknown}, limit=${limit:-unknown}, required=+$required)"
}

cleanup_expired_validation_resource_groups() {
  local now_epoch
  local resource_group
  local expires_at
  local expires_epoch
  local pinned_reuse_group=""

  now_epoch="$(date -u +%s)"
  pinned_reuse_group="$EXISTING_DB_RESOURCE_GROUP"

  while IFS=$'\t' read -r resource_group expires_at; do
    [[ -n "$resource_group" && -n "$expires_at" ]] || continue

    expires_epoch="$(date -u -d "$expires_at" +%s 2>/dev/null || echo 0)"
    if (( expires_epoch == 0 || expires_epoch >= now_epoch )); then
      continue
    fi

    if [[ -n "$DATA_RESOURCE_GROUP" && "$resource_group" == "$DATA_RESOURCE_GROUP" ]]; then
      continue
    fi

    if [[ -n "$pinned_reuse_group" && "$resource_group" == "$pinned_reuse_group" ]]; then
      continue
    fi

    log_warn "Deleting expired Azure validation resource group $resource_group (ExpiresAtUTC=$expires_at)"
    run_az group delete --name "$resource_group" --yes --no-wait || log_warn "Failed to submit delete for expired group $resource_group"
  done < <(
    run_az group list \
      --query "[?tags.Owner=='terraform-validation' && location=='${LOCATION}'].[name,tags.ExpiresAtUTC]" \
      -o tsv
  )
}

detect_db_firewall_ips() {
  if [[ -n "$DB_FIREWALL_START_IP" && -z "$DB_FIREWALL_END_IP" ]]; then
    log_error "HONUA_AZURE_DB_FIREWALL_END_IP must be set when HONUA_AZURE_DB_FIREWALL_START_IP is provided"
    exit 1
  fi

  if [[ -z "$DB_FIREWALL_START_IP" && -n "$DB_FIREWALL_END_IP" ]]; then
    log_error "HONUA_AZURE_DB_FIREWALL_START_IP must be set when HONUA_AZURE_DB_FIREWALL_END_IP is provided"
    exit 1
  fi

  if [[ -n "$DB_FIREWALL_START_IP" && -n "$DB_FIREWALL_END_IP" ]]; then
    log_info "Using provided DB firewall range: $DB_FIREWALL_START_IP - $DB_FIREWALL_END_IP"
    return
  fi

  local detected_ip
  detected_ip="$(detect_public_ipv4 || true)"
  if [[ -z "$detected_ip" ]]; then
    log_error "No DB firewall range provided and public IPv4 detection failed. Set HONUA_AZURE_DB_FIREWALL_START_IP and HONUA_AZURE_DB_FIREWALL_END_IP explicitly."
    exit 1
  fi

  DB_FIREWALL_START_IP="$detected_ip"
  DB_FIREWALL_END_IP="$detected_ip"
  log_info "No DB firewall range provided; using detected runner egress IP ${detected_ip}/32"
}

detect_public_ipv4() {
  local candidate=""
  local endpoint
  for endpoint in "https://api.ipify.org" "https://ifconfig.me/ip"; do
    candidate="$(curl -fsS --max-time 10 "$endpoint" 2>/dev/null || true)"
    if [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

delete_rg_if_exists() {
  local resource_group="$1"

  if run_az group show -n "$resource_group" >/dev/null 2>&1; then
    log_warn "Janitor submitting resource group delete for $resource_group"
    run_az group delete --name "$resource_group" --yes --no-wait || log_warn "Failed to submit delete for $resource_group"
  fi
}

janitor_delete_resource_groups() {
  local keep_data_stack="$1"

  if [[ "$DATA_APPLIED" == "true" && "$keep_data_stack" != "true" ]]; then
    if [[ -n "$DATA_RESOURCE_GROUP" ]]; then
      delete_rg_if_exists "$DATA_RESOURCE_GROUP"
    else
      delete_rg_if_exists "${DATA_NAME_PREFIX}-${ENVIRONMENT}-data-rg"
    fi
  fi

  if [[ "$STACK" == "aca" || "$STACK" == "both" ]]; then
    delete_rg_if_exists "${ACA_NAME_PREFIX}-${ENVIRONMENT}-rg"
  fi

  if [[ "$STACK" == "functions" || "$STACK" == "both" ]]; then
    delete_rg_if_exists "${FUNCTIONS_NAME_PREFIX}-${ENVIRONMENT}-rg"
  fi
}

verify_no_leaks() {
  local count
  local i

  for i in {1..10}; do
    count="$(run_az resource list --tag ValidationRunId="$VALIDATION_RUN_ID" --query "length(@)" -o tsv || echo 0)"
    if [[ "$count" == "0" ]]; then
      log_info "Leak janitor check passed (no tagged resources remain)"
      return 0
    fi
    sleep 15
  done

  log_error "Leak janitor check failed: resources tagged ValidationRunId=$VALIDATION_RUN_ID still exist"
  run_az resource list --tag ValidationRunId="$VALIDATION_RUN_ID" -o table || true
  return 1
}

cleanup() {
  local exit_code="$?"
  local keep_data_stack=false
  local skip_leak_check=false

  clear_existing_db_firewall_access

  if [[ "$AUTO_DESTROY" == "true" ]]; then
    destroy_functions_stack
    destroy_aca_stack
    clear_functions_db_firewall_access
    clear_aca_db_firewall_access
    if [[ "$DESTROY_DATA" == "true" ]]; then
      destroy_data_stack
    elif [[ "$DATA_APPLIED" == "true" ]]; then
      if [[ "$DATA_CREATED" == "true" ]]; then
        if [[ "$exit_code" -eq 0 ]]; then
          log_warn "Keeping Azure data stack for reuse (set --destroy-data to tear it down)"
        else
          log_warn "Azure compute validation failed after the data stack was created; keeping the Azure data stack for reuse because destroy-data is disabled"
        fi
        keep_data_stack=true
        skip_leak_check=true
      else
        log_warn "Azure run reused an existing data stack; leaving it in place"
        skip_leak_check=true
      fi
    fi
    janitor_delete_resource_groups "$keep_data_stack"
    if [[ "$skip_leak_check" == "false" ]]; then
      verify_no_leaks || exit_code=1
    fi
  else
    log_warn "Auto-destroy disabled; resources were left in Azure"
  fi

  if [[ -n "$TEMP_TF_ROOT" && -d "$TEMP_TF_ROOT" ]]; then
    rm -rf "$TEMP_TF_ROOT"
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    log_error "Azure Terraform integration run failed"
  fi

  exit "$exit_code"
}
