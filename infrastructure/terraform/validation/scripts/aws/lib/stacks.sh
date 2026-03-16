# Sourced by validation.sh after config, network, runtime, and verification helpers are defined.

apply_data_stack() {
  log_info "Applying AWS data stack (RDS + Redis)"
  set_data_tf_vars

  run_tf -chdir=examples/aws-data init -input=false -no-color
  plan_apply "examples/aws-data" "data.tfplan" "data"

  EXISTING_DB_ENDPOINT="$(run_tf -chdir=examples/aws-data output -raw db_endpoint)"
  EXISTING_DB_CONNECTION_STRING="$(run_tf -chdir=examples/aws-data output -raw db_connection_string)"
  EXISTING_REDIS_CONNECTION_STRING="$(run_tf -chdir=examples/aws-data output -raw redis_connection_string)"
  EXISTING_VPC_ID="$(run_tf -chdir=examples/aws-data output -raw vpc_id)"
  EXISTING_VPC_CIDR="$(run_tf -chdir=examples/aws-data output -raw vpc_cidr)"
  EXISTING_PUBLIC_SUBNET_IDS="$(run_tf -chdir=examples/aws-data output -json public_subnet_ids | tr -d '\n')"
  EXISTING_PRIVATE_SUBNET_IDS="$(run_tf -chdir=examples/aws-data output -json private_subnet_ids | tr -d '\n')"

  if [[ -z "$EXISTING_DB_ENDPOINT" || -z "$EXISTING_DB_CONNECTION_STRING" || -z "$EXISTING_REDIS_CONNECTION_STRING" || -z "$EXISTING_VPC_ID" || -z "$EXISTING_VPC_CIDR" || -z "$EXISTING_PUBLIC_SUBNET_IDS" || -z "$EXISTING_PRIVATE_SUBNET_IDS" ]]; then
    log_error "AWS data stack output validation failed (missing DB/Redis/VPC output)"
    return 1
  fi

  DATA_APPLIED=true
  DATA_CREATED=true

  if [[ "$CHECK_IDEMPOTENCY" == "true" ]]; then
    assert_idempotent_plan "examples/aws-data"
  fi

  persist_data_reuse_cache
  log_info "AWS data stack ready: vpc=$EXISTING_VPC_ID db=$EXISTING_DB_ENDPOINT"
}

apply_ecs_stack() {
  local url
  local db_endpoint
  local redis_endpoint
  local cluster_name
  local service_name
  local tf_output_json

  log_info "Applying AWS ECS stack"
  set_ecs_tf_vars

  run_tf -chdir=examples/aws init -input=false -no-color
  # Mark stack as applied before first plan/apply so cleanup destroys partial resources on failed apply.
  ECS_APPLIED=true

  if [[ "$RUN_UPGRADE_ROLLBACK" == "true" ]]; then
    if [[ -z "$ECS_PREVIOUS_IMAGE" || "$ECS_PREVIOUS_IMAGE" == "$ECS_IMAGE" ]]; then
      log_error "ECS upgrade/rollback requires --ecs-previous-image different from --ecs-image"
      return 1
    fi

    export TF_VAR_honua_image="$ECS_PREVIOUS_IMAGE"
    plan_apply "examples/aws" "ecs-prev.tfplan" "ecs-previous"

    url="$(run_tf -chdir=examples/aws output -raw honua_url)"
    db_endpoint="$(run_tf -chdir=examples/aws output -raw db_endpoint)"
    cluster_name="$(run_tf -chdir=examples/aws output -raw ecs_cluster_name)"
    service_name="$(run_tf -chdir=examples/aws output -raw ecs_service_name)"

    if [[ -n "$EXISTING_REDIS_CONNECTION_STRING" ]]; then
      log_info "Using existing Redis connection string; skipping ECS Redis endpoint creation check"
    else
      redis_endpoint="$(run_tf -chdir=examples/aws output -raw redis_primary_endpoint)"
      if [[ -z "$redis_endpoint" || "$redis_endpoint" == "null" ]]; then
        log_error "Redis endpoint was empty for ECS stack"
        return 1
      fi
    fi

    run_ecs_checks "$url" "$db_endpoint"
    verify_ecs_canary_route "$url" "$cluster_name"

    export TF_VAR_honua_image="$ECS_IMAGE"
    plan_apply "examples/aws" "ecs-upgrade.tfplan" "ecs-upgrade"
    url="$(run_tf -chdir=examples/aws output -raw honua_url)"
    db_endpoint="$(run_tf -chdir=examples/aws output -raw db_endpoint)"
    run_ecs_checks "$url" "$db_endpoint"
    verify_ecs_canary_route "$url" "$cluster_name"

    if [[ "$QUICK_SCALE" == "true" ]]; then
      log_info "Running quick ECS scale validation by raising desired_count to $ECS_SCALE_TARGET_DESIRED_COUNT"
      export TF_VAR_desired_count="$ECS_SCALE_TARGET_DESIRED_COUNT"
      plan_apply "examples/aws" "ecs-scale.tfplan" "ecs-scale"
      wait_for_ecs_running_count "$cluster_name" "$service_name" "$ECS_SCALE_TARGET_DESIRED_COUNT" 900
      export TF_VAR_desired_count="$ECS_DESIRED_COUNT"
      plan_apply "examples/aws" "ecs-scale-reset.tfplan" "ecs-scale-reset"
      if [[ "$ECS_DESIRED_COUNT" =~ ^[0-9]+$ ]] && (( ECS_DESIRED_COUNT > 0 )); then
        wait_for_ecs_running_count "$cluster_name" "$service_name" "$ECS_DESIRED_COUNT" 900
      fi
    fi

    export TF_VAR_honua_image="$ECS_PREVIOUS_IMAGE"
    plan_apply "examples/aws" "ecs-rollback.tfplan" "ecs-rollback"
    run_ecs_checks "$url" "$db_endpoint"
    verify_ecs_canary_route "$url" "$cluster_name"

    if [[ "$AUTO_DESTROY" != "true" ]]; then
      export TF_VAR_honua_image="$ECS_IMAGE"
      plan_apply "examples/aws" "ecs-restore-current.tfplan" "ecs-restore-current"
      run_ecs_checks "$url" "$db_endpoint"
      verify_ecs_canary_route "$url" "$cluster_name"
    fi

    export TF_VAR_honua_image="$ECS_IMAGE"
  else
    plan_apply "examples/aws" "ecs.tfplan" "ecs"

    url="$(run_tf -chdir=examples/aws output -raw honua_url)"
    db_endpoint="$(run_tf -chdir=examples/aws output -raw db_endpoint)"
    cluster_name="$(run_tf -chdir=examples/aws output -raw ecs_cluster_name)"
    service_name="$(run_tf -chdir=examples/aws output -raw ecs_service_name)"

    if [[ -n "$EXISTING_REDIS_CONNECTION_STRING" ]]; then
      log_info "Using existing Redis connection string; skipping ECS Redis endpoint creation check"
    else
      redis_endpoint="$(run_tf -chdir=examples/aws output -raw redis_primary_endpoint)"
      if [[ -z "$redis_endpoint" || "$redis_endpoint" == "null" ]]; then
        log_error "Redis endpoint was empty for ECS stack"
        return 1
      fi
    fi

    run_ecs_checks "$url" "$db_endpoint"
    verify_ecs_canary_route "$url" "$cluster_name"

    if [[ "$QUICK_SCALE" == "true" ]]; then
      log_info "Running quick ECS scale validation by raising desired_count to $ECS_SCALE_TARGET_DESIRED_COUNT"
      export TF_VAR_desired_count="$ECS_SCALE_TARGET_DESIRED_COUNT"
      plan_apply "examples/aws" "ecs-scale.tfplan" "ecs-scale"
      wait_for_ecs_running_count "$cluster_name" "$service_name" "$ECS_SCALE_TARGET_DESIRED_COUNT" 900
      export TF_VAR_desired_count="$ECS_DESIRED_COUNT"
      plan_apply "examples/aws" "ecs-scale-reset.tfplan" "ecs-scale-reset"
      if [[ "$ECS_DESIRED_COUNT" =~ ^[0-9]+$ ]] && (( ECS_DESIRED_COUNT > 0 )); then
        wait_for_ecs_running_count "$cluster_name" "$service_name" "$ECS_DESIRED_COUNT" 900
      fi
    fi
  fi

  ECS_APPLIED=true

  if [[ "$CHECK_IDEMPOTENCY" == "true" ]]; then
    assert_idempotent_plan "examples/aws"
  fi

  tf_output_json="$(mktemp "${TMPDIR:-/tmp}/honua-aws-ecs-outputs.XXXXXX.json")"
  run_tf -chdir=examples/aws output -json > "$tf_output_json"

  HONUA_PLATFORM_VALIDATION_TERRAFORM_OUTPUT_JSON="$tf_output_json" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_HOST="$db_endpoint" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_PORT="5432" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_NAME="honua" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_USERNAME="honua" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_PASSWORD="$DB_PASSWORD_EFFECTIVE" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_SSL_MODE="Require" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_SSL_REQUIRED="true" \
  run_honua_platform_post_apply_validation "$url" "aws-ecs"

  log_info "ECS stack checks passed"
  log_info "ECS URL: $(run_tf -chdir=examples/aws output -raw honua_url)"
}

apply_serverless_stack() {
  local url
  local db_endpoint
  local redis_connection
  local tf_output_json
  local previous_live_revision
  local desired_revision

  if [[ -z "$SERVERLESS_IMAGE" ]]; then
    log_error "Serverless image is required. Set HONUA_AWS_SERVERLESS_IMAGE or pass --serverless-image"
    return 1
  fi

  log_info "Applying AWS serverless stack"
  set_serverless_tf_vars

  run_tf -chdir=examples/aws-serverless init -input=false -no-color
  # Mark stack as applied before first plan/apply so cleanup destroys partial resources on failed apply.
  SERVERLESS_APPLIED=true

  if [[ "$RUN_UPGRADE_ROLLBACK" == "true" ]]; then
    if [[ -z "$SERVERLESS_PREVIOUS_IMAGE" || "$SERVERLESS_PREVIOUS_IMAGE" == "$SERVERLESS_IMAGE" ]]; then
      log_error "Serverless upgrade/rollback requires --serverless-previous-image different from --serverless-image"
      return 1
    fi

    export TF_VAR_honua_image_uri="$SERVERLESS_PREVIOUS_IMAGE"
    plan_apply "examples/aws-serverless" "serverless-prev.tfplan" "serverless-previous"

    url="$(run_tf -chdir=examples/aws-serverless output -raw honua_url)"
    db_endpoint="$(run_tf -chdir=examples/aws-serverless output -raw db_endpoint)"
    redis_connection="$(run_tf -chdir=examples/aws-serverless output -raw redis_connection_string)"

    if [[ -z "$redis_connection" || "$redis_connection" == "null" ]]; then
      log_error "Redis connection string was empty for serverless stack"
      return 1
    fi

    run_serverless_checks "$url" "$db_endpoint"
    previous_live_revision="$(run_tf -chdir=examples/aws-serverless output -raw control_plane_current_revision)"
    if [[ -z "$previous_live_revision" || "$previous_live_revision" == "null" ]]; then
      log_error "Serverless validation requires a stable Lambda alias revision before publishing the new version"
      return 1
    fi

    export TF_VAR_honua_image_uri="$SERVERLESS_IMAGE"
    export TF_VAR_lambda_alias_version="$previous_live_revision"
    plan_apply "examples/aws-serverless" "serverless-stage-current.tfplan" "serverless-stage-current"
    url="$(run_tf -chdir=examples/aws-serverless output -raw honua_url)"
    db_endpoint="$(run_tf -chdir=examples/aws-serverless output -raw db_endpoint)"
    desired_revision="$(run_tf -chdir=examples/aws-serverless output -raw control_plane_desired_revision)"
    if [[ -z "$desired_revision" || "$desired_revision" == "null" || "$desired_revision" == "$previous_live_revision" ]]; then
      log_error "Serverless validation requires a newly published Lambda version that differs from the stable alias revision"
      return 1
    fi
    run_serverless_checks "$url" "$db_endpoint"
  else
    plan_apply "examples/aws-serverless" "serverless.tfplan" "serverless"

    url="$(run_tf -chdir=examples/aws-serverless output -raw honua_url)"
    db_endpoint="$(run_tf -chdir=examples/aws-serverless output -raw db_endpoint)"
    redis_connection="$(run_tf -chdir=examples/aws-serverless output -raw redis_connection_string)"

    if [[ -z "$redis_connection" || "$redis_connection" == "null" ]]; then
      log_error "Redis connection string was empty for serverless stack"
      return 1
    fi

    run_serverless_checks "$url" "$db_endpoint"
  fi

  if [[ "$CHECK_IDEMPOTENCY" == "true" ]]; then
    assert_idempotent_plan "examples/aws-serverless"
  fi

  tf_output_json="$(mktemp "${TMPDIR:-/tmp}/honua-aws-serverless-outputs.XXXXXX.json")"
  run_tf -chdir=examples/aws-serverless output -json > "$tf_output_json"

  HONUA_PLATFORM_VALIDATION_TERRAFORM_OUTPUT_JSON="$tf_output_json" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_HOST="$db_endpoint" \
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
  run_honua_platform_post_apply_validation "$url" "aws-lambda"

  if [[ "$RUN_UPGRADE_ROLLBACK" == "true" ]]; then
    unset TF_VAR_lambda_alias_version
    export TF_VAR_honua_image_uri="$SERVERLESS_IMAGE"
    plan_apply "examples/aws-serverless" "serverless-reconcile-current.tfplan" "serverless-reconcile-current"
    url="$(run_tf -chdir=examples/aws-serverless output -raw honua_url)"
    db_endpoint="$(run_tf -chdir=examples/aws-serverless output -raw db_endpoint)"
    run_serverless_checks "$url" "$db_endpoint"
  fi

  log_info "Serverless stack checks passed"
  log_info "Serverless URL: $(run_tf -chdir=examples/aws-serverless output -raw honua_url)"
}

destroy_ecs_stack() {
  if [[ "$ECS_APPLIED" != "true" ]]; then
    return
  fi

  log_info "Destroying AWS ECS stack"
  set_ecs_tf_vars
  run_tf -chdir=examples/aws destroy -input=false -auto-approve -no-color || log_warn "ECS destroy encountered errors"
}

destroy_serverless_stack() {
  if [[ "$SERVERLESS_APPLIED" != "true" ]]; then
    return
  fi

  log_info "Destroying AWS serverless stack"
  set_serverless_tf_vars
  run_tf -chdir=examples/aws-serverless destroy -input=false -auto-approve -no-color || log_warn "Serverless destroy encountered errors"
}

destroy_data_stack() {
  if [[ "$DATA_APPLIED" != "true" || "$DATA_CREATED" != "true" ]]; then
    return
  fi

  log_info "Destroying AWS data stack"
  set_data_tf_vars
  if run_tf -chdir=examples/aws-data destroy -input=false -auto-approve -no-color; then
    clear_data_reuse_cache
  else
    log_warn "Data stack destroy encountered errors"
  fi
}

verify_no_leaks() {
  local arns_raw
  local -a arns
  local -a leaking_arns
  local arn
  local i

  is_non_leaking_tagged_arn() {
    local resource_arn="$1"
    local status
    local deleted_date
    local key_state
    local cluster_name
    local service_name
    local service_path

    case "$resource_arn" in
      arn:aws:ecs:*:cluster/*)
        cluster_name="${resource_arn##*/}"
        status="$(run_aws ecs describe-clusters --clusters "$cluster_name" --query 'clusters[0].status' --output text 2>/dev/null || echo MISSING)"
        [[ "$status" != "ACTIVE" ]]
        return
        ;;
      arn:aws:ecs:*:service/*/*)
        service_path="${resource_arn#*:service/}"
        cluster_name="${service_path%%/*}"
        service_name="${service_path#*/}"
        status="$(run_aws ecs describe-services --cluster "$cluster_name" --services "$service_name" --query 'services[0].status' --output text 2>/dev/null || echo MISSING)"
        [[ "$status" != "ACTIVE" ]]
        return
        ;;
      arn:aws:ecs:*:task-definition/*)
        status="$(run_aws ecs describe-task-definition --task-definition "$resource_arn" --query 'taskDefinition.status' --output text 2>/dev/null || echo MISSING)"
        [[ "$status" == "INACTIVE" || "$status" == "MISSING" ]]
        return
        ;;
      arn:aws:secretsmanager:*)
        deleted_date="$(run_aws secretsmanager describe-secret --secret-id "$resource_arn" --query 'DeletedDate' --output text 2>/dev/null || echo MISSING)"
        [[ "$deleted_date" != "None" ]]
        return
        ;;
      arn:aws:kms:*)
        key_state="$(run_aws kms describe-key --key-id "$resource_arn" --query 'KeyMetadata.KeyState' --output text 2>/dev/null || echo MISSING)"
        [[ "$key_state" == "PendingDeletion" || "$key_state" == "PendingReplicaDeletion" || "$key_state" == "MISSING" ]]
        return
        ;;
      *)
        return 1
        ;;
    esac
  }

  collect_leaking_arns() {
    arns_raw="$(run_aws resourcegroupstaggingapi get-resources --tag-filters Key=ValidationRunId,Values="$VALIDATION_RUN_ID" --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || echo '')"

    arns=()
    if [[ -n "$arns_raw" && "$arns_raw" != "None" ]]; then
      # AWS CLI text output is tab-delimited for lists.
      # shellcheck disable=SC2206
      arns=( ${arns_raw//$'\t'/$'\n'} )
    fi

    leaking_arns=()
    for arn in "${arns[@]}"; do
      if ! is_non_leaking_tagged_arn "$arn"; then
        leaking_arns+=("$arn")
      fi
    done
  }

  for i in {1..20}; do
    collect_leaking_arns
    if [[ "${#leaking_arns[@]}" -eq 0 ]]; then
      log_info "Leak janitor check passed (no tagged resources remain)"
      return 0
    fi

    log_info "Leak janitor waiting for ${#leaking_arns[@]} resource(s) to clear (attempt $i/20)"
    sleep 15
  done

  log_error "Leak janitor check failed: resources tagged ValidationRunId=$VALIDATION_RUN_ID still exist as active/leaking resources"
  printf '%s\n' "${leaking_arns[@]}" >&2
  return 1
}

cleanup() {
  local exit_code="$?"
  local skip_leak_check=false

  revoke_existing_db_runner_ingress || exit_code=1

  if [[ "$AUTO_DESTROY" == "true" ]]; then
    destroy_serverless_stack
    destroy_ecs_stack
    if [[ "$DESTROY_DATA" == "true" ]]; then
      destroy_data_stack
    elif [[ "$DATA_APPLIED" == "true" && "$DATA_CREATED" == "true" ]]; then
      log_warn "Keeping AWS data stack for reuse (explicit keep-data mode enabled)"
      skip_leak_check=true
    fi

    if [[ "$skip_leak_check" == "false" ]]; then
      verify_no_leaks || exit_code=1
    fi
  else
    log_warn "Auto-destroy disabled; resources were left in AWS"
  fi

  if [[ -n "$TEMP_TF_ROOT" && -d "$TEMP_TF_ROOT" ]]; then
    rm -rf "$TEMP_TF_ROOT" || true
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    log_error "AWS Terraform integration run failed"
  fi

  exit "$exit_code"
}
