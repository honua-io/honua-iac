# Sourced by validation.sh after config and network helpers are defined.

detect_db_ingress_cidr() {
  if [[ -n "$DB_INGRESS_CIDR" ]]; then
    return
  fi

  local ip
  ip="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
  if [[ -z "$ip" ]]; then
    log_error "Failed to detect public IP for db ingress"
    exit 1
  fi

  DB_INGRESS_CIDR="${ip}/32"
}

detect_http_ingress_cidr() {
  if [[ -n "$HTTP_INGRESS_CIDR" ]]; then
    return
  fi

  local ip
  if [[ -n "$DB_INGRESS_CIDR" ]]; then
    ip="${DB_INGRESS_CIDR%/32}"
  else
    ip="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
  fi

  if [[ -z "$ip" ]]; then
    log_error "Failed to detect public IP for HTTP ingress"
    exit 1
  fi

  HTTP_INGRESS_CIDR="${ip}/32"
}

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
  if [[ "$FORCE_DOCKER_TF" == "true" ]]; then
    require_command docker
    build_tf_image_if_needed
    USE_DOCKER_TF=true
  elif command -v terraform >/dev/null 2>&1; then
    USE_DOCKER_TF=false
  else
    require_command docker
    build_tf_image_if_needed
    USE_DOCKER_TF=true
  fi

  if command -v aws >/dev/null 2>&1; then
    USE_DOCKER_AWS_CLI=false
  else
    require_command docker
    USE_DOCKER_AWS_CLI=true
  fi

  if [[ "$FORCE_DOCKER_PG_TOOLS" == "true" ]]; then
    require_command docker
    USE_DOCKER_PG_TOOLS=true
  elif command -v psql >/dev/null 2>&1 && command -v pg_dump >/dev/null 2>&1 && command -v pg_restore >/dev/null 2>&1; then
    USE_DOCKER_PG_TOOLS=false
  else
    require_command docker
    USE_DOCKER_PG_TOOLS=true
  fi

  log_info "Terraform executor: $([[ "$USE_DOCKER_TF" == "true" ]] && echo docker || echo local)"
  log_info "AWS CLI executor: $([[ "$USE_DOCKER_AWS_CLI" == "true" ]] && echo docker || echo local)"
  log_info "Postgres tools executor: $([[ "$USE_DOCKER_PG_TOOLS" == "true" ]] && echo docker || echo local)"
}

prepare_tf_workspace() {
  TEMP_TF_ROOT="$(mktemp -d)"
  cp -R "$REPO_ROOT/infrastructure/terraform" "$TEMP_TF_ROOT/terraform"
}

run_tf() {
  if [[ "$USE_DOCKER_TF" == "true" ]]; then
    docker run --rm \
      -e AWS_ACCESS_KEY_ID \
      -e AWS_SECRET_ACCESS_KEY \
      -e AWS_SESSION_TOKEN \
      -e AWS_REGION \
      -e AWS_DEFAULT_REGION \
      -e TF_VAR_region \
      -e TF_VAR_environment \
      -e TF_VAR_name_prefix \
      -e TF_VAR_honua_admin_password \
      -e TF_VAR_db_password \
      -e TF_VAR_existing_db_endpoint \
      -e TF_VAR_existing_db_connection_string \
      -e TF_VAR_existing_vpc_id \
      -e TF_VAR_existing_vpc_cidr \
      -e TF_VAR_existing_public_subnet_ids \
      -e TF_VAR_existing_private_subnet_ids \
      -e TF_VAR_honua_image \
      -e TF_VAR_honua_image_uri \
      -e TF_VAR_enable_postgis \
      -e TF_VAR_redis_enabled \
      -e TF_VAR_redis_connection_string \
      -e TF_VAR_db_publicly_accessible \
      -e TF_VAR_db_additional_ingress_cidrs \
      -e TF_VAR_desired_count \
      -e TF_VAR_canary_enabled \
      -e TF_VAR_canary_image \
      -e TF_VAR_canary_desired_count \
      -e TF_VAR_canary_weight_percentage \
      -e TF_VAR_canary_header_name \
      -e TF_VAR_canary_header_value \
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

run_aws() {
  if [[ "$USE_DOCKER_AWS_CLI" == "true" ]]; then
    docker run --rm \
      -e AWS_ACCESS_KEY_ID \
      -e AWS_SECRET_ACCESS_KEY \
      -e AWS_SESSION_TOKEN \
      -e AWS_REGION \
      -e AWS_DEFAULT_REGION \
      "$AWS_CLI_IMAGE" "$@"
    return
  fi

  AWS_PAGER="" aws --region "$REGION" "$@"
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
  run_tf_apply_with_auth_retry "$root" "$plan_file"
}

run_tf_apply_with_auth_retry() {
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

    if grep -Eq "ExpiredToken|ExpiredTokenException|RequestExpired" "$apply_log" && [[ "$attempt" -lt 2 ]]; then
      log_warn "Terraform apply failed due to expired AWS credentials; retrying apply once"
      rm -f "$apply_log"
      continue
    fi

    rm -f "$apply_log"
    return "$exit_code"
  done
}

estimate_stack_cost() {
  local stack_name="$1"
  local base=0
  local include_data=false

  case "$stack_name" in
    data) base=25 ;;
    ecs) base=50 ;;
    serverless) base=25 ;;
    both) base=75 ;;
    *) base=0 ;;
  esac

  if [[ "$stack_name" == "data" ]]; then
    include_data=true
  elif ! has_existing_data_inputs; then
    include_data=true
  fi

  if [[ "$include_data" == "true" && "$stack_name" != "data" ]]; then
    base=$((base + 25))
  fi

  echo "$base"
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

run_quota_preflight() {
  local quota
  local required
  local needs_data_stack

  if [[ "$RUN_QUOTA_PREFLIGHT" != "true" ]]; then
    return
  fi

  quota="$(run_aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query 'Quota.Value' --output text 2>/dev/null || echo '')"

  required=0
  needs_data_stack=false
  if [[ "$STACK" == "data" ]]; then
    needs_data_stack=true
  elif [[ -z "$EXISTING_DB_CONNECTION_STRING" || -z "$EXISTING_REDIS_CONNECTION_STRING" || -z "$EXISTING_VPC_ID" ]]; then
    needs_data_stack=true
  fi

  if [[ "$needs_data_stack" == "true" ]]; then
    required=$((required + 2))
  fi

  if [[ "$STACK" == "ecs" || "$STACK" == "both" ]]; then
    required=$((required + 4))
  fi
  if [[ "$STACK" == "serverless" || "$STACK" == "both" ]]; then
    required=$((required + 2))
  fi

  if [[ -n "$quota" && "$quota" != "None" ]] && awk -v q="$quota" -v r="$required" 'BEGIN { exit !(r > q) }'; then
    log_error "AWS quota preflight failed: estimated required vCPU $required exceeds EC2 regional quota $quota"
    exit 1
  fi

  log_info "AWS quota preflight passed (EC2 regional vCPU quota=${quota:-unknown}, required~$required)"
}

cache_file_is_safe_to_read() {
  if [[ ! -f "$DATA_CACHE_FILE" ]]; then
    return 1
  fi

  if [[ -L "$DATA_CACHE_FILE" ]]; then
    log_warn "Ignoring AWS data cache file symlink: $DATA_CACHE_FILE"
    return 1
  fi

  if [[ ! -r "$DATA_CACHE_FILE" ]]; then
    log_warn "Ignoring unreadable AWS data cache file: $DATA_CACHE_FILE"
    return 1
  fi

  return 0
}

cache_encode_value() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

cache_decode_into_var() {
  local key="$1"
  local encoded_value="$2"
  local decoded_value

  if ! decoded_value="$(printf '%s' "$encoded_value" | base64 --decode 2>/dev/null)"; then
    return 1
  fi

  printf -v "$key" '%s' "$decoded_value"
}

load_data_reuse_cache() {
  local line
  local key
  local value
  local format_seen

  if [[ "$FORCE_NEW_DATA_INFRA" == "true" ]]; then
    log_info "Force-new-data-infra enabled; ignoring cached AWS data inputs"
    return
  fi

  if [[ "$DESTROY_DATA" == "true" ]]; then
    return
  fi

  if has_existing_data_inputs; then
    return
  fi

  if ! cache_file_is_safe_to_read; then
    return
  fi

  format_seen=false
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" != *=* ]]; then
      log_warn "Malformed AWS data cache file (missing '='): $DATA_CACHE_FILE"
      return
    fi

    key="${line%%=*}"
    value="${line#*=}"

    case "$key" in
      HONUA_CACHE_FORMAT)
        if [[ "$value" != "$DATA_CACHE_FORMAT" ]]; then
          log_warn "Unsupported AWS data cache format in $DATA_CACHE_FILE (expected $DATA_CACHE_FORMAT)"
          return
        fi
        format_seen=true
        ;;
      EXISTING_DB_ENDPOINT|EXISTING_DB_CONNECTION_STRING|EXISTING_REDIS_CONNECTION_STRING|EXISTING_VPC_ID|EXISTING_VPC_CIDR|EXISTING_PUBLIC_SUBNET_IDS|EXISTING_PRIVATE_SUBNET_IDS)
        if ! cache_decode_into_var "$key" "$value"; then
          log_warn "Failed decoding AWS data cache key '$key' in $DATA_CACHE_FILE"
          return
        fi
        ;;
      *)
        log_warn "Ignoring unexpected AWS data cache key '$key' in $DATA_CACHE_FILE"
        ;;
    esac
  done < "$DATA_CACHE_FILE"

  if [[ "$format_seen" != "true" ]]; then
    log_warn "AWS data cache file missing format marker; ignoring cache: $DATA_CACHE_FILE"
    return
  fi

  if has_existing_data_inputs; then
    log_info "Loaded AWS data reuse inputs from $DATA_CACHE_FILE"
  else
    log_warn "Data cache file exists but is incomplete: $DATA_CACHE_FILE"
  fi
}

persist_data_reuse_cache() {
  if [[ "$DESTROY_DATA" == "true" ]]; then
    return
  fi

  local cache_dir
  local tmp_file

  cache_dir="$(dirname "$DATA_CACHE_FILE")"
  mkdir -p "$cache_dir"

  tmp_file="$(mktemp "$cache_dir/honua-aws-data-cache.XXXXXX")"
  chmod 600 "$tmp_file"
  cat > "$tmp_file" <<EOF
HONUA_CACHE_FORMAT=$DATA_CACHE_FORMAT
EXISTING_DB_ENDPOINT=$(cache_encode_value "$EXISTING_DB_ENDPOINT")
EXISTING_DB_CONNECTION_STRING=$(cache_encode_value "$EXISTING_DB_CONNECTION_STRING")
EXISTING_REDIS_CONNECTION_STRING=$(cache_encode_value "$EXISTING_REDIS_CONNECTION_STRING")
EXISTING_VPC_ID=$(cache_encode_value "$EXISTING_VPC_ID")
EXISTING_VPC_CIDR=$(cache_encode_value "$EXISTING_VPC_CIDR")
EXISTING_PUBLIC_SUBNET_IDS=$(cache_encode_value "$EXISTING_PUBLIC_SUBNET_IDS")
EXISTING_PRIVATE_SUBNET_IDS=$(cache_encode_value "$EXISTING_PRIVATE_SUBNET_IDS")
EOF
  mv "$tmp_file" "$DATA_CACHE_FILE"

  log_info "Saved AWS data reuse inputs to $DATA_CACHE_FILE"
}

clear_data_reuse_cache() {
  if [[ -f "$DATA_CACHE_FILE" ]]; then
    rm -f "$DATA_CACHE_FILE"
    log_info "Cleared AWS data reuse cache: $DATA_CACHE_FILE"
  fi
}

set_common_tf_vars() {
  EXPIRES_AT_UTC="$(date -u -d "+${TTL_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"

  ensure_existing_db_connection_string_shape
  ensure_existing_redis_connection_string_shape

  export AWS_REGION="$REGION"
  export AWS_DEFAULT_REGION="$REGION"
  export TF_VAR_region="$REGION"
  export TF_VAR_environment="$ENVIRONMENT"
  export TF_VAR_honua_admin_password="$HONUA_ADMIN_PASSWORD"
  export TF_VAR_db_password="$HONUA_DB_PASSWORD"
  export TF_VAR_existing_db_endpoint="$EXISTING_DB_ENDPOINT"
  export TF_VAR_existing_db_connection_string="$EXISTING_DB_CONNECTION_STRING"
  export TF_VAR_existing_vpc_id="$EXISTING_VPC_ID"
  export TF_VAR_existing_vpc_cidr="$EXISTING_VPC_CIDR"
  export TF_VAR_existing_public_subnet_ids="${EXISTING_PUBLIC_SUBNET_IDS:-[]}"
  export TF_VAR_existing_private_subnet_ids="${EXISTING_PRIVATE_SUBNET_IDS:-[]}"
  export TF_VAR_enable_postgis="true"
  export TF_VAR_postgis_readiness_max_attempts="$POSTGIS_READINESS_MAX_ATTEMPTS"
  export TF_VAR_postgis_readiness_sleep_seconds="$POSTGIS_READINESS_SLEEP_SECONDS"
  export TF_VAR_redis_enabled="true"
  export TF_VAR_redis_connection_string="$EXISTING_REDIS_CONNECTION_STRING"
  if [[ -n "$EXISTING_REDIS_CONNECTION_STRING" && -n "$EXISTING_VPC_CIDR" ]]; then
    export TF_VAR_redis_connection_cidrs="[\"$EXISTING_VPC_CIDR\"]"
  else
    export TF_VAR_redis_connection_cidrs="[]"
  fi
  export TF_VAR_db_publicly_accessible="true"
  export TF_VAR_allow_http_ingress_cidrs="[\"$HTTP_INGRESS_CIDR\"]"
  if [[ -n "$EXISTING_DB_CONNECTION_STRING" ]]; then
    export TF_VAR_db_additional_ingress_cidrs="[]"
  else
    export TF_VAR_db_additional_ingress_cidrs="[\"$DB_INGRESS_CIDR\"]"
  fi
  export TF_VAR_tags="{\"ValidationRunId\":\"$VALIDATION_RUN_ID\",\"TTLHours\":\"$TTL_HOURS\",\"ExpiresAtUTC\":\"$EXPIRES_AT_UTC\",\"Owner\":\"terraform-validation\"}"
}

set_ecs_tf_vars() {
  ensure_existing_vpc_private_egress
  set_common_tf_vars
  export TF_VAR_name_prefix="$ECS_NAME_PREFIX"
  export TF_VAR_honua_image="$ECS_IMAGE"
  export TF_VAR_desired_count="$ECS_DESIRED_COUNT"
  export TF_VAR_alb_deletion_protection="false"
  export TF_VAR_alb_access_logs_enabled="false"
  export TF_VAR_alb_access_logs_force_destroy="true"
  export TF_VAR_canary_enabled="$ECS_CANARY_ENABLED"
  export TF_VAR_canary_image="$ECS_CANARY_IMAGE"
  export TF_VAR_canary_desired_count="$ECS_CANARY_DESIRED_COUNT"
  export TF_VAR_canary_weight_percentage="$ECS_CANARY_WEIGHT_PERCENTAGE"
  export TF_VAR_canary_header_name="$ECS_CANARY_HEADER_NAME"
  export TF_VAR_canary_header_value="$ECS_CANARY_HEADER_VALUE"

  unset TF_VAR_honua_image_uri
  unset TF_VAR_skip_migrations
}

set_serverless_tf_vars() {
  ensure_existing_vpc_private_egress
  set_common_tf_vars
  export TF_VAR_name_prefix="$SERVERLESS_NAME_PREFIX"
  export TF_VAR_honua_image_uri="$SERVERLESS_IMAGE"
  export TF_VAR_skip_migrations="true"

  unset TF_VAR_honua_image
  unset TF_VAR_desired_count
  unset TF_VAR_canary_enabled
  unset TF_VAR_canary_image
  unset TF_VAR_canary_desired_count
  unset TF_VAR_canary_weight_percentage
  unset TF_VAR_canary_header_name
  unset TF_VAR_canary_header_value
  unset TF_VAR_lambda_alias_version
}

set_data_tf_vars() {
  set_common_tf_vars
  export TF_VAR_name_prefix="$DATA_NAME_PREFIX"
  export TF_VAR_existing_db_endpoint=""
  export TF_VAR_existing_db_connection_string=""
  export TF_VAR_existing_vpc_id=""
  export TF_VAR_existing_vpc_cidr=""
  export TF_VAR_existing_public_subnet_ids="[]"
  export TF_VAR_existing_private_subnet_ids="[]"
  export TF_VAR_db_publicly_accessible="true"
  export TF_VAR_db_additional_ingress_cidrs="[\"$DB_INGRESS_CIDR\"]"
  export TF_VAR_redis_enabled="true"

  unset TF_VAR_honua_image
  unset TF_VAR_honua_image_uri
  unset TF_VAR_desired_count
  unset TF_VAR_skip_migrations
  unset TF_VAR_canary_enabled
  unset TF_VAR_canary_image
  unset TF_VAR_canary_desired_count
  unset TF_VAR_canary_weight_percentage
  unset TF_VAR_canary_header_name
  unset TF_VAR_canary_header_value
}
