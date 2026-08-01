# Sourced by run-azure-terraform-integration.sh after the common logging,
# runtime, config, verification, and network helpers have been defined.

set_common_tf_vars() {
  ensure_existing_db_connection_string_shape
  ensure_existing_redis_connection_string_shape

  # Azure Managed Identity tag reads normalize this value to MM/DD/YYYY HH:MM:SS.
  # Use that format up-front to keep idempotency checks stable across services.
  EXPIRES_AT_UTC="$(date -u -d "+${TTL_HOURS} hours" +%m/%d/%Y\ %H:%M:%S)"

  export TF_VAR_location="$LOCATION"
  export TF_VAR_environment="$ENVIRONMENT"
  export TF_VAR_honua_admin_password="$HONUA_ADMIN_PASSWORD"
  export TF_VAR_honua_connection_encryption_master_key="$HONUA_ADMIN_PASSWORD"
  export TF_VAR_db_admin_password="$HONUA_DB_PASSWORD"
  export TF_VAR_enable_postgis="true"
  export TF_VAR_redis_enabled="true"
  export TF_VAR_redis_connection_string="$EXISTING_REDIS_CONNECTION_STRING"
  export TF_VAR_existing_db_fqdn="$EXISTING_DB_FQDN"
  export TF_VAR_existing_db_connection_string="$EXISTING_DB_CONNECTION_STRING"
  export TF_VAR_db_firewall_start_ip="$DB_FIREWALL_START_IP"
  export TF_VAR_db_firewall_end_ip="$DB_FIREWALL_END_IP"
  export TF_VAR_tags="{\"ValidationRunId\":\"$VALIDATION_RUN_ID\",\"TTLHours\":\"$TTL_HOURS\",\"ExpiresAtUTC\":\"$EXPIRES_AT_UTC\",\"Owner\":\"terraform-validation\"}"
}

set_aca_tf_vars() {
  set_common_tf_vars
  resolve_acr_credentials_from_image "$ACA_IMAGE"
  export TF_VAR_name_prefix="$ACA_NAME_PREFIX"
  export TF_VAR_honua_image="$ACA_IMAGE"
  export TF_VAR_min_replicas="$ACA_MIN_REPLICAS"
  export TF_VAR_max_replicas="$ACA_MAX_REPLICAS"
  export TF_VAR_key_vault_default_action="Allow"
  export TF_VAR_registry_server="$REGISTRY_SERVER"
  export TF_VAR_registry_username="$REGISTRY_USERNAME"
  export TF_VAR_registry_password="$REGISTRY_PASSWORD"

  unset TF_VAR_plan_sku_name
  unset TF_VAR_skip_migrations
  unset TF_VAR_db_sku_name
  unset TF_VAR_db_storage_mb
  unset TF_VAR_db_geo_redundant_backup_enabled
  unset TF_VAR_db_backup_retention_days
  unset TF_VAR_db_public_network_access
  unset TF_VAR_redis_sku_name
  unset TF_VAR_redis_family
  unset TF_VAR_redis_capacity
  unset TF_VAR_redis_public_network_access_enabled
}

set_functions_tf_vars() {
  set_common_tf_vars
  resolve_acr_credentials_from_image "$FUNCTIONS_IMAGE"
  export TF_VAR_name_prefix="$FUNCTIONS_NAME_PREFIX"
  export TF_VAR_honua_image="$FUNCTIONS_IMAGE"
  export TF_VAR_deployment_slot_enabled="$FUNCTIONS_DEPLOYMENT_SLOT_ENABLED"
  export TF_VAR_deployment_slot_name="$FUNCTIONS_DEPLOYMENT_SLOT_NAME"
  export TF_VAR_deployment_slot_image="$FUNCTIONS_DEPLOYMENT_SLOT_IMAGE"
  export TF_VAR_plan_sku_name="$FUNCTIONS_PLAN_SKU"
  export TF_VAR_skip_migrations="$FUNCTIONS_SKIP_MIGRATIONS"
  export TF_VAR_key_vault_public_network_access_enabled="true"
  export TF_VAR_storage_network_default_action="Allow"
  export TF_VAR_registry_server="$REGISTRY_SERVER"
  export TF_VAR_registry_username="$REGISTRY_USERNAME"
  export TF_VAR_registry_password="$REGISTRY_PASSWORD"

  unset TF_VAR_min_replicas
  unset TF_VAR_max_replicas
  unset TF_VAR_key_vault_default_action
  unset TF_VAR_db_sku_name
  unset TF_VAR_db_storage_mb
  unset TF_VAR_db_geo_redundant_backup_enabled
  unset TF_VAR_db_backup_retention_days
  unset TF_VAR_db_public_network_access
  unset TF_VAR_redis_sku_name
  unset TF_VAR_redis_family
  unset TF_VAR_redis_capacity
  unset TF_VAR_redis_public_network_access_enabled
}

set_data_tf_vars() {
  set_common_tf_vars
  export TF_VAR_name_prefix="$DATA_NAME_PREFIX"
  export TF_VAR_key_vault_default_action="Allow"
  export TF_VAR_db_sku_name="$DATA_DB_SKU_NAME"
  export TF_VAR_db_storage_mb="$DATA_DB_STORAGE_MB"
  export TF_VAR_db_geo_redundant_backup_enabled="$DATA_DB_GEO_REDUNDANT_BACKUP_ENABLED"
  export TF_VAR_db_backup_retention_days="$DATA_DB_BACKUP_RETENTION_DAYS"
  export TF_VAR_db_public_network_access="$DATA_DB_PUBLIC_NETWORK_ACCESS"
  export TF_VAR_redis_sku_name="$DATA_REDIS_SKU_NAME"
  export TF_VAR_redis_family="$DATA_REDIS_FAMILY"
  export TF_VAR_redis_capacity="$DATA_REDIS_CAPACITY"
  export TF_VAR_redis_public_network_access_enabled="$DATA_REDIS_PUBLIC_NETWORK_ACCESS_ENABLED"

  unset TF_VAR_honua_image
  unset TF_VAR_plan_sku_name
  unset TF_VAR_skip_migrations
  unset TF_VAR_min_replicas
  unset TF_VAR_max_replicas
}

apply_data_stack() {
  if [[ "$AUTO_PROVISION_DATA_STACK" != "true" ]]; then
    return
  fi

  log_info "Applying Azure data stack"
  set_data_tf_vars

  run_tf -chdir=examples/azure-data init -input=false -no-color
  # Mark stack as applied before first plan/apply so cleanup destroys partial resources on failed apply.
  DATA_APPLIED=true

  plan_apply "examples/azure-data" "data.tfplan" "azure-data"

  EXISTING_DB_FQDN="$(run_tf -chdir=examples/azure-data output -raw db_fqdn)"
  EXISTING_DB_CONNECTION_STRING="$(run_tf -chdir=examples/azure-data output -raw db_connection_string)"
  EXISTING_REDIS_CONNECTION_STRING="$(run_tf -chdir=examples/azure-data output -raw redis_connection_string)"
  DATA_RESOURCE_GROUP="$(run_tf -chdir=examples/azure-data output -raw resource_group_name)"
  EXISTING_DB_RESOURCE_GROUP="$DATA_RESOURCE_GROUP"

  if [[ -z "$EXISTING_DB_FQDN" || -z "$EXISTING_DB_CONNECTION_STRING" ]]; then
    log_error "Azure data stack output validation failed: db_fqdn/db_connection_string must be non-empty"
    return 1
  fi

  if [[ -z "$EXISTING_REDIS_CONNECTION_STRING" ]]; then
    log_error "Azure data stack output validation failed: redis_connection_string must be non-empty"
    return 1
  fi

  if [[ "$CHECK_IDEMPOTENCY" == "true" ]]; then
    assert_idempotent_plan "examples/azure-data"
  fi

  DATA_CREATED=true
  persist_data_reuse_cache
  log_info "Azure data stack ready: resource_group=$DATA_RESOURCE_GROUP"
}

run_aca_checks() {
  local url="$1"
  local db_fqdn="$2"
  local resource_group="$3"
  local app_name="$4"
  local redis_resource_group="$resource_group"

  if [[ "$DATA_APPLIED" == "true" && -n "$DATA_RESOURCE_GROUP" ]]; then
    redis_resource_group="$DATA_RESOURCE_GROUP"
  fi

  ensure_aca_db_firewall_access "$resource_group" "$app_name" "$db_fqdn"
  if ! wait_for_ready "$url" "$TIMEOUT_SECONDS"; then
    diagnose_aca_failure "$resource_group" "$app_name"
    return 1
  fi
  if [[ "$CHECK_PROTOCOLS" == "true" ]]; then
    run_admin_api_crud_smoke "$url" "$db_fqdn"
    verify_protocol_endpoints "$url"
  fi
  verify_redis_exists "$redis_resource_group"
  verify_postgis_extensions "$db_fqdn"
  if [[ "$RUN_DB_RESILIENCE" == "true" ]]; then
    verify_db_backup_restore "$db_fqdn"
  fi
  run_load_probe "$url" "$LOAD_REQUESTS" "$LOAD_CONCURRENCY"
}

run_functions_checks() {
  local url="$1"
  local db_fqdn="$2"
  local resource_group="$3"
  local app_name="$4"
  local redis_resource_group="$resource_group"

  if [[ "$DATA_APPLIED" == "true" && -n "$DATA_RESOURCE_GROUP" ]]; then
    redis_resource_group="$DATA_RESOURCE_GROUP"
  fi

  ensure_functions_db_firewall_access "$resource_group" "$app_name" "$db_fqdn"
  if ! wait_for_ready "$url" "$TIMEOUT_SECONDS"; then
    diagnose_functions_failure "$resource_group" "$app_name"
    return 1
  fi
  if [[ "$CHECK_PROTOCOLS" == "true" ]]; then
    run_admin_api_crud_smoke "$url" "$db_fqdn"
    verify_protocol_endpoints "$url"
  fi
  verify_redis_exists "$redis_resource_group"
  verify_postgis_extensions "$db_fqdn"
  if [[ "$RUN_DB_RESILIENCE" == "true" ]]; then
    verify_db_backup_restore "$db_fqdn"
  fi
  run_load_probe "$url" "$LOAD_REQUESTS" "$LOAD_CONCURRENCY"
}

apply_aca_stack() {
  local url
  local db_fqdn
  local resource_group
  local app_name
  local tf_output_json

  log_info "Applying Azure ACA stack"
  set_aca_tf_vars

  run_tf -chdir=examples/azure init -input=false -no-color
  # Mark stack as applied before first plan/apply so cleanup destroys partial resources on failed apply.
  ACA_APPLIED=true

  if [[ "$RUN_UPGRADE_ROLLBACK" == "true" ]]; then
    if [[ -z "$ACA_PREVIOUS_IMAGE" || "$ACA_PREVIOUS_IMAGE" == "$ACA_IMAGE" ]]; then
      log_error "ACA upgrade/rollback requires --aca-previous-image different from --aca-image"
      return 1
    fi

    export TF_VAR_honua_image="$ACA_PREVIOUS_IMAGE"
    plan_apply "examples/azure" "aca-prev.tfplan" "aca-previous"
    url="$(run_tf -chdir=examples/azure output -raw honua_url)"
    db_fqdn="$(run_tf -chdir=examples/azure output -raw database_fqdn)"
    resource_group="$(run_tf -chdir=examples/azure output -raw resource_group_name)"
    app_name="$(run_tf -chdir=examples/azure output -raw container_app_name)"
    run_aca_checks "$url" "$db_fqdn" "$resource_group" "$app_name"

    export TF_VAR_honua_image="$ACA_IMAGE"
    plan_apply "examples/azure" "aca-upgrade.tfplan" "aca-upgrade"
    url="$(run_tf -chdir=examples/azure output -raw honua_url)"
    db_fqdn="$(run_tf -chdir=examples/azure output -raw database_fqdn)"
    resource_group="$(run_tf -chdir=examples/azure output -raw resource_group_name)"
    app_name="$(run_tf -chdir=examples/azure output -raw container_app_name)"
    run_aca_checks "$url" "$db_fqdn" "$resource_group" "$app_name"

    if [[ "$QUICK_SCALE" == "true" ]]; then
      log_info "Running quick ACA scale validation by raising min replicas to $ACA_SCALE_TARGET_MIN_REPLICAS"
      export TF_VAR_min_replicas="$ACA_SCALE_TARGET_MIN_REPLICAS"
      plan_apply "examples/azure" "aca-scale.tfplan" "aca-scale"
      wait_for_aca_replicas "$resource_group" "$app_name" "$ACA_SCALE_TARGET_MIN_REPLICAS" 600
      export TF_VAR_min_replicas="$ACA_MIN_REPLICAS"
      plan_apply "examples/azure" "aca-scale-reset.tfplan" "aca-scale-reset"
      if [[ "$ACA_MIN_REPLICAS" =~ ^[0-9]+$ ]] && (( ACA_MIN_REPLICAS > 0 )); then
        wait_for_aca_replicas "$resource_group" "$app_name" "$ACA_MIN_REPLICAS" 600
      fi
    fi

    export TF_VAR_honua_image="$ACA_PREVIOUS_IMAGE"
    plan_apply "examples/azure" "aca-rollback.tfplan" "aca-rollback"
    run_aca_checks "$url" "$db_fqdn" "$resource_group" "$app_name"

    if [[ "$AUTO_DESTROY" != "true" ]]; then
      export TF_VAR_honua_image="$ACA_IMAGE"
      plan_apply "examples/azure" "aca-restore-current.tfplan" "aca-restore-current"
      run_aca_checks "$url" "$db_fqdn" "$resource_group" "$app_name"
    fi

    export TF_VAR_honua_image="$ACA_IMAGE"
  else
    plan_apply "examples/azure" "aca.tfplan" "aca"

    url="$(run_tf -chdir=examples/azure output -raw honua_url)"
    db_fqdn="$(run_tf -chdir=examples/azure output -raw database_fqdn)"
    resource_group="$(run_tf -chdir=examples/azure output -raw resource_group_name)"
    app_name="$(run_tf -chdir=examples/azure output -raw container_app_name)"

    run_aca_checks "$url" "$db_fqdn" "$resource_group" "$app_name"

    if [[ "$QUICK_SCALE" == "true" ]]; then
      log_info "Running quick ACA scale validation by raising min replicas to $ACA_SCALE_TARGET_MIN_REPLICAS"
      export TF_VAR_min_replicas="$ACA_SCALE_TARGET_MIN_REPLICAS"
      plan_apply "examples/azure" "aca-scale.tfplan" "aca-scale"
      wait_for_aca_replicas "$resource_group" "$app_name" "$ACA_SCALE_TARGET_MIN_REPLICAS" 600
      export TF_VAR_min_replicas="$ACA_MIN_REPLICAS"
      plan_apply "examples/azure" "aca-scale-reset.tfplan" "aca-scale-reset"
      if [[ "$ACA_MIN_REPLICAS" =~ ^[0-9]+$ ]] && (( ACA_MIN_REPLICAS > 0 )); then
        wait_for_aca_replicas "$resource_group" "$app_name" "$ACA_MIN_REPLICAS" 600
      fi
    fi
  fi

  if [[ "$CHECK_IDEMPOTENCY" == "true" ]]; then
    assert_idempotent_plan "examples/azure"
  fi

  tf_output_json="$(mktemp "${TMPDIR:-/tmp}/honua-azure-aca-outputs.XXXXXX.json")"
  run_tf -chdir=examples/azure output -json > "$tf_output_json"

  HONUA_PLATFORM_VALIDATION_TERRAFORM_OUTPUT_JSON="$tf_output_json" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_HOST="$db_fqdn" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_PORT="5432" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_NAME="honua" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_USERNAME="honua" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_PASSWORD="$DB_PASSWORD_EFFECTIVE" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_SSL_MODE="Require" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_SSL_REQUIRED="true" \
  run_honua_platform_post_apply_validation "$url" "azure-container-apps"

  log_info "ACA stack checks passed"
  log_info "ACA URL: $(run_tf -chdir=examples/azure output -raw honua_url)"
}

apply_functions_stack() {
  local url
  local db_fqdn
  local resource_group
  local app_name
  local tf_output_json
  local previous_live_revision
  local desired_revision

  log_info "Applying Azure Functions stack"
  set_functions_tf_vars

  run_tf -chdir=examples/azure-functions init -input=false -no-color
  # Mark stack as applied before first plan/apply so cleanup destroys partial resources on failed apply.
  FUNCTIONS_APPLIED=true

  if [[ "$RUN_UPGRADE_ROLLBACK" == "true" ]]; then
    if [[ -z "$FUNCTIONS_PREVIOUS_IMAGE" || "$FUNCTIONS_PREVIOUS_IMAGE" == "$FUNCTIONS_IMAGE" ]]; then
      log_error "Functions upgrade/rollback requires --functions-previous-image different from --functions-image"
      return 1
    fi

    export TF_VAR_deployment_slot_enabled="true"
    export TF_VAR_deployment_slot_name="$FUNCTIONS_DEPLOYMENT_SLOT_NAME"

    export TF_VAR_honua_image="$FUNCTIONS_PREVIOUS_IMAGE"
    export TF_VAR_deployment_slot_image="$FUNCTIONS_PREVIOUS_IMAGE"
    plan_apply "examples/azure-functions" "functions-prev.tfplan" "functions-previous"
    url="$(run_tf -chdir=examples/azure-functions output -raw honua_url)"
    db_fqdn="$(run_tf -chdir=examples/azure-functions output -raw db_fqdn)"
    resource_group="$(run_tf -chdir=examples/azure-functions output -raw resource_group_name)"
    app_name="$(run_tf -chdir=examples/azure-functions output -raw function_app_name)"
    run_functions_checks "$url" "$db_fqdn" "$resource_group" "$app_name"
    previous_live_revision="$(run_tf -chdir=examples/azure-functions output -raw control_plane_current_revision)"
    if [[ -z "$previous_live_revision" || "$previous_live_revision" == "null" ]]; then
      log_error "Functions validation requires control_plane_current_revision once the deployment slot is enabled"
      return 1
    fi

    export TF_VAR_honua_image="$FUNCTIONS_PREVIOUS_IMAGE"
    export TF_VAR_deployment_slot_image="$FUNCTIONS_IMAGE"
    plan_apply "examples/azure-functions" "functions-stage-current.tfplan" "functions-stage-current"
    url="$(run_tf -chdir=examples/azure-functions output -raw honua_url)"
    db_fqdn="$(run_tf -chdir=examples/azure-functions output -raw db_fqdn)"
    resource_group="$(run_tf -chdir=examples/azure-functions output -raw resource_group_name)"
    app_name="$(run_tf -chdir=examples/azure-functions output -raw function_app_name)"
    desired_revision="$(run_tf -chdir=examples/azure-functions output -raw control_plane_desired_revision)"
    if [[ -z "$desired_revision" || "$desired_revision" == "null" ]]; then
      log_error "Functions validation requires control_plane_desired_revision once the deployment slot is enabled"
      return 1
    fi
    run_functions_checks "$url" "$db_fqdn" "$resource_group" "$app_name"
  else
    plan_apply "examples/azure-functions" "functions.tfplan" "functions"

    url="$(run_tf -chdir=examples/azure-functions output -raw honua_url)"
    db_fqdn="$(run_tf -chdir=examples/azure-functions output -raw db_fqdn)"
    resource_group="$(run_tf -chdir=examples/azure-functions output -raw resource_group_name)"
    app_name="$(run_tf -chdir=examples/azure-functions output -raw function_app_name)"

    run_functions_checks "$url" "$db_fqdn" "$resource_group" "$app_name"
  fi

  if [[ "$CHECK_IDEMPOTENCY" == "true" ]]; then
    assert_idempotent_plan "examples/azure-functions"
  fi

  tf_output_json="$(mktemp "${TMPDIR:-/tmp}/honua-azure-functions-outputs.XXXXXX.json")"
  run_tf -chdir=examples/azure-functions output -json > "$tf_output_json"

  HONUA_PLATFORM_VALIDATION_TERRAFORM_OUTPUT_JSON="$tf_output_json" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_HOST="$db_fqdn" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_PORT="5432" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_NAME="honua" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_USERNAME="honua" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_PASSWORD="$DB_PASSWORD_EFFECTIVE" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_SSL_MODE="Require" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_SSL_REQUIRED="true" \
  HONUA_PLATFORM_VALIDATION_DEPLOY_CURRENT_REVISION="${previous_live_revision:-}" \
  HONUA_PLATFORM_VALIDATION_DEPLOY_DESIRED_REVISION="${desired_revision:-}" \
  HONUA_PLATFORM_VALIDATION_EXECUTE_DEPLOY_OPERATION="$([[ "$RUN_UPGRADE_ROLLBACK" == "true" ]] && printf 'true' || printf 'false')" \
  HONUA_PLATFORM_VALIDATION_VERIFY_DEPLOY_ROLLBACK="$([[ "$RUN_UPGRADE_ROLLBACK" == "true" ]] && printf 'true' || printf 'false')" \
  HONUA_PLATFORM_VALIDATION_DEPLOY_TIMEOUT_SECONDS="240" \
  run_honua_platform_post_apply_validation "$url" "azure-functions" || {
    diagnose_functions_failure "$resource_group" "$app_name"
    return 1
  }

  if [[ "$RUN_UPGRADE_ROLLBACK" == "true" ]]; then
    export TF_VAR_honua_image="$FUNCTIONS_IMAGE"
    export TF_VAR_deployment_slot_enabled="true"
    export TF_VAR_deployment_slot_name="$FUNCTIONS_DEPLOYMENT_SLOT_NAME"
    export TF_VAR_deployment_slot_image="$FUNCTIONS_IMAGE"
    plan_apply "examples/azure-functions" "functions-reconcile-current.tfplan" "functions-reconcile-current"
    url="$(run_tf -chdir=examples/azure-functions output -raw honua_url)"
    db_fqdn="$(run_tf -chdir=examples/azure-functions output -raw db_fqdn)"
    resource_group="$(run_tf -chdir=examples/azure-functions output -raw resource_group_name)"
    app_name="$(run_tf -chdir=examples/azure-functions output -raw function_app_name)"
    run_functions_checks "$url" "$db_fqdn" "$resource_group" "$app_name"
  fi

  log_info "Functions stack checks passed"
  log_info "Functions URL: $(run_tf -chdir=examples/azure-functions output -raw honua_url)"
}

destroy_aca_stack() {
  if [[ "$ACA_APPLIED" != "true" ]]; then
    return
  fi

  log_info "Destroying Azure ACA stack"
  set_aca_tf_vars
  run_tf -chdir=examples/azure destroy -input=false -auto-approve -no-color || log_warn "ACA destroy encountered errors"
}

destroy_functions_stack() {
  if [[ "$FUNCTIONS_APPLIED" != "true" ]]; then
    return
  fi

  log_info "Destroying Azure Functions stack"
  set_functions_tf_vars
  run_tf -chdir=examples/azure-functions destroy -input=false -auto-approve -no-color || log_warn "Functions destroy encountered errors"
}

destroy_data_stack() {
  if [[ "$DATA_APPLIED" != "true" ]]; then
    return
  fi

  log_info "Destroying Azure data stack"
  set_data_tf_vars
  if run_tf -chdir=examples/azure-data destroy -input=false -auto-approve -no-color; then
    clear_data_reuse_cache
  else
    log_warn "Data stack destroy encountered errors"
  fi
}
