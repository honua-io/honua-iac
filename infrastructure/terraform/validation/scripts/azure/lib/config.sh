# Sourced by run-azure-terraform-integration.sh after the common logging and
# runtime helpers have been defined.

validate_requested_images() {
  if [[ "$STACK" == "aca" || "$STACK" == "both" ]]; then
    if [[ -z "$ACA_IMAGE" ]]; then
      log_error "ACA image is required. Set HONUA_ACA_IMAGE or pass --aca-image."
      exit 1
    fi

    if [[ "$RUN_UPGRADE_ROLLBACK" == "true" && -z "$ACA_PREVIOUS_IMAGE" ]]; then
      log_error "ACA upgrade/rollback requires HONUA_ACA_PREVIOUS_IMAGE or --aca-previous-image."
      exit 1
    fi
  fi

  if [[ "$STACK" == "functions" || "$STACK" == "both" ]]; then
    if [[ -z "$FUNCTIONS_IMAGE" ]]; then
      log_error "Functions image is required. Set HONUA_FUNCTIONS_IMAGE or pass --functions-image."
      exit 1
    fi

    if [[ "$RUN_UPGRADE_ROLLBACK" == "true" && -z "$FUNCTIONS_PREVIOUS_IMAGE" ]]; then
      log_error "Functions upgrade/rollback requires HONUA_FUNCTIONS_PREVIOUS_IMAGE or --functions-previous-image."
      exit 1
    fi
  fi
}

extract_connection_string_password() {
  local connection_string="$1"
  local field

  IFS=';' read -r -a fields <<< "$connection_string"
  for field in "${fields[@]}"; do
    field="${field#"${field%%[![:space:]]*}"}"
    case "$field" in
      [Pp]assword=*)
        printf '%s' "${field#*=}"
        return 0
        ;;
    esac
  done

  return 1
}

convert_pg_uri_to_connection_string() {
  local connection_uri="$1"

  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  python3 - "$connection_uri" <<'PY'
import sys
from urllib.parse import parse_qs, unquote, urlparse

uri = sys.argv[1]
parsed = urlparse(uri)
if parsed.scheme not in {"postgres", "postgresql"}:
    sys.exit(1)

host = parsed.hostname or ""
user = unquote(parsed.username or "")
password = unquote(parsed.password or "")
database = (parsed.path or "/").lstrip("/") or "honua"
port = parsed.port or 5432
query = parse_qs(parsed.query, keep_blank_values=True)
ssl_mode = (query.get("sslmode") or query.get("ssl_mode") or ["Require"])[0]
trust_server_certificate = (
    query.get("trust server certificate")
    or query.get("trust_server_certificate")
    or ["false"]
)[0]

parts = [
    f"Host={host}",
    f"Port={port}",
    f"Database={database}",
    f"Username={user}",
]
if password:
    parts.append(f"Password={password}")
parts.append(f"SSL Mode={ssl_mode}")
parts.append(f"Trust Server Certificate={trust_server_certificate}")
print(";".join(parts))
PY
}

normalize_existing_db_connection_string() {
  local normalized="$1"
  local converted=""

  normalized="$(printf '%s' "$normalized" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  case "$normalized" in
    ConnectionStrings__DefaultConnection=*)
      normalized="${normalized#ConnectionStrings__DefaultConnection=}"
      ;;
    DefaultConnection=*)
      normalized="${normalized#DefaultConnection=}"
      ;;
  esac

  if [[ "$normalized" == \"*\" && "$normalized" == *\" ]]; then
    normalized="${normalized:1:${#normalized}-2}"
  fi

  if [[ "$normalized" == \'*\' && "$normalized" == *\' ]]; then
    normalized="${normalized:1:${#normalized}-2}"
  fi

  if [[ "$normalized" =~ ^postgres(ql)?:// ]]; then
    if converted="$(convert_pg_uri_to_connection_string "$normalized" 2>/dev/null)" && [[ -n "$converted" ]]; then
      normalized="$converted"
    fi
  fi

  printf '%s' "$normalized"
}

normalize_existing_redis_connection_string() {
  local normalized="$1"

  normalized="$(printf '%s' "$normalized" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  case "$normalized" in
    ConnectionStrings__Redis=*)
      normalized="${normalized#ConnectionStrings__Redis=}"
      ;;
    Redis=*)
      normalized="${normalized#Redis=}"
      ;;
  esac

  if [[ "$normalized" == \"*\" && "$normalized" == *\" ]]; then
    normalized="${normalized:1:${#normalized}-2}"
  fi

  if [[ "$normalized" == \'*\' && "$normalized" == *\' ]]; then
    normalized="${normalized:1:${#normalized}-2}"
  fi

  printf '%s' "$normalized"
}

extract_registry_server_from_image() {
  local image_ref="$1"
  local first_segment=""

  first_segment="${image_ref%%/*}"
  if [[ "$first_segment" == "$image_ref" ]]; then
    return 1
  fi

  case "$first_segment" in
    *.*|*:*|localhost)
      printf '%s' "$first_segment"
      return 0
      ;;
  esac

  return 1
}

resolve_acr_credentials_from_image() {
  local image_ref="$1"
  local registry_name=""

  if [[ -n "$REGISTRY_SERVER" && -n "$REGISTRY_USERNAME" && -n "$REGISTRY_PASSWORD" ]]; then
    return 0
  fi

  if ! REGISTRY_SERVER="$(extract_registry_server_from_image "$image_ref")"; then
    return 0
  fi

  if [[ ! "$REGISTRY_SERVER" =~ \.azurecr\.io$ ]]; then
    return 0
  fi

  registry_name="${REGISTRY_SERVER%%.*}"
  if [[ -z "$registry_name" ]]; then
    log_error "Could not derive Azure Container Registry name from image: $image_ref"
    exit 1
  fi

  log_info "Resolving ACR credentials for ${REGISTRY_SERVER}"
  local attempt
  local credentials_resolved=false

  for attempt in $(seq 1 "$AZ_LOGIN_MAX_ATTEMPTS"); do
    if run_az acr update --name "$registry_name" --admin-enabled true >/dev/null 2>&1; then
      REGISTRY_USERNAME="$(run_az acr credential show --name "$registry_name" --query username -o tsv 2>/dev/null || true)"
      REGISTRY_PASSWORD="$(run_az acr credential show --name "$registry_name" --query 'passwords[0].value' -o tsv 2>/dev/null || true)"
      if [[ -n "$REGISTRY_USERNAME" && -n "$REGISTRY_PASSWORD" ]]; then
        credentials_resolved=true
        break
      fi
    fi

    if (( attempt < AZ_LOGIN_MAX_ATTEMPTS )); then
      log_warn "ACR credentials not ready yet for ${REGISTRY_SERVER}; retrying in ${AZ_LOGIN_RETRY_SECONDS}s (attempt ${attempt}/${AZ_LOGIN_MAX_ATTEMPTS})"
      sleep "$AZ_LOGIN_RETRY_SECONDS"
    fi
  done

  if [[ "$credentials_resolved" != "true" ]]; then
    log_error "Could not resolve ACR credentials for ${REGISTRY_SERVER}"
    exit 1
  fi
}

infer_existing_redis_name_from_db_fqdn() {
  local db_host="$1"
  local base_name="${db_host%%.*}"

  if [[ "$base_name" == *-pg ]]; then
    base_name="${base_name%-pg}"
  fi

  if [[ -z "$base_name" ]]; then
    return 1
  fi

  printf '%s-redis' "$base_name"
}

infer_existing_redis_resource_group_from_db_fqdn() {
  local db_host="$1"
  local base_name="${db_host%%.*}"

  if [[ "$base_name" == *-pg ]]; then
    base_name="${base_name%-pg}"
  fi

  if [[ -z "$base_name" ]]; then
    return 1
  fi

  printf '%s-data-rg' "$base_name"
}

infer_existing_postgres_resource_group_from_db_fqdn() {
  local db_host="$1"
  local base_name="${db_host%%.*}"

  if [[ "$base_name" == *-pg ]]; then
    base_name="${base_name%-pg}"
  fi

  if [[ -z "$base_name" ]]; then
    return 1
  fi

  printf '%s-data-rg' "$base_name"
}

rebuild_existing_redis_connection_string_from_azure() {
  local redis_name="$1"
  local redis_resource_group="$2"
  local redis_host=""
  local redis_ssl_port=""
  local redis_primary_key=""

  redis_host="$(run_az redis show \
    --resource-group "$redis_resource_group" \
    --name "$redis_name" \
    --query hostName \
    -o tsv 2>/dev/null || true)"

  redis_ssl_port="$(run_az redis show \
    --resource-group "$redis_resource_group" \
    --name "$redis_name" \
    --query sslPort \
    -o tsv 2>/dev/null || true)"

  redis_primary_key="$(run_az redis list-keys \
    --resource-group "$redis_resource_group" \
    --name "$redis_name" \
    --query primaryKey \
    -o tsv 2>/dev/null || true)"

  if [[ -z "$redis_host" || "$redis_host" == "None" || "$redis_host" == "null" ]]; then
    return 1
  fi

  if [[ -z "$redis_ssl_port" || "$redis_ssl_port" == "None" || "$redis_ssl_port" == "null" ]]; then
    redis_ssl_port="6380"
  fi

  if [[ -z "$redis_primary_key" || "$redis_primary_key" == "None" || "$redis_primary_key" == "null" ]]; then
    return 1
  fi

  printf '%s' "${redis_host}:${redis_ssl_port},password=${redis_primary_key},ssl=True,abortConnect=False"
}

ensure_existing_redis_connection_string_shape() {
  local normalized=""
  local redis_name=""
  local redis_resource_group=""
  local rebuilt=""

  if [[ -z "$EXISTING_REDIS_CONNECTION_STRING" ]]; then
    return 0
  fi

  normalized="$(normalize_existing_redis_connection_string "$EXISTING_REDIS_CONNECTION_STRING")"

  if [[ "$normalized" != "$EXISTING_REDIS_CONNECTION_STRING" ]]; then
    log_info "Normalized reused Azure Redis connection string before Terraform apply"
    EXISTING_REDIS_CONNECTION_STRING="$normalized"
  fi

  if [[ "$EXISTING_REDIS_CONNECTION_STRING" == *","* && "$EXISTING_REDIS_CONNECTION_STRING" == *"password="* && "$EXISTING_REDIS_CONNECTION_STRING" != -* ]]; then
    return 0
  fi

  if [[ -n "$EXISTING_DB_FQDN" ]]; then
    if [[ -z "$EXISTING_DB_RESOURCE_GROUP" ]]; then
      EXISTING_DB_RESOURCE_GROUP="$(infer_existing_postgres_resource_group_from_db_fqdn "$EXISTING_DB_FQDN" 2>/dev/null || true)"
      if [[ -n "$EXISTING_DB_RESOURCE_GROUP" ]]; then
        log_info "Inferred existing DB resource group: $EXISTING_DB_RESOURCE_GROUP"
      fi
    fi

    if redis_name="$(infer_existing_redis_name_from_db_fqdn "$EXISTING_DB_FQDN")" && \
       redis_resource_group="$(infer_existing_redis_resource_group_from_db_fqdn "$EXISTING_DB_FQDN")" && \
       rebuilt="$(rebuild_existing_redis_connection_string_from_azure "$redis_name" "$redis_resource_group")" && \
       [[ -n "$rebuilt" ]]; then
      log_warn "Reused Azure Redis connection string was not valid; rebuilding from existing Azure Redis cache metadata"
      EXISTING_REDIS_CONNECTION_STRING="$rebuilt"
      return 0
    fi
  fi

  log_error "Reused Azure Redis connection string is invalid and could not be rebuilt from Azure metadata"
  exit 1
}

ensure_existing_db_connection_string_shape() {
  local normalized=""

  if [[ -z "$EXISTING_DB_CONNECTION_STRING" ]]; then
    return 0
  fi

  normalized="$(normalize_existing_db_connection_string "$EXISTING_DB_CONNECTION_STRING")"

  if [[ "$normalized" != "$EXISTING_DB_CONNECTION_STRING" ]]; then
    log_info "Normalized reused Azure DB connection string before Terraform apply"
    EXISTING_DB_CONNECTION_STRING="$normalized"
  fi

  if [[ "$EXISTING_DB_CONNECTION_STRING" != *=* ]]; then
    if [[ -n "$EXISTING_DB_FQDN" ]]; then
      log_warn "Reused Azure DB connection string was not ADO.NET-shaped; rebuilding from existing DB FQDN and validation defaults"
      EXISTING_DB_CONNECTION_STRING="Host=${EXISTING_DB_FQDN};Port=5432;Database=honua;Username=honua;Password=${HONUA_DB_PASSWORD};SSL Mode=Require;Trust Server Certificate=false"
      return 0
    fi

    log_error "Reused Azure DB connection string is not a valid ADO.NET connection string and no existing DB FQDN fallback is available"
    exit 1
  fi
}

resolve_db_password_for_checks() {
  DB_PASSWORD_EFFECTIVE="$HONUA_DB_PASSWORD"

  if [[ -n "$EXISTING_DB_CONNECTION_STRING" ]]; then
    local parsed_password
    if parsed_password="$(extract_connection_string_password "$EXISTING_DB_CONNECTION_STRING")" && [[ -n "$parsed_password" ]]; then
      DB_PASSWORD_EFFECTIVE="$parsed_password"
      log_info "Using DB password parsed from existing DB connection string for smoke checks"
    else
      log_warn "Could not parse password from existing DB connection string; using HONUA_DB_PASSWORD for smoke checks"
    fi
  fi
}

validate_admin_password() {
  if (( ${#HONUA_ADMIN_PASSWORD} < 32 )); then
    log_error "HONUA_ADMIN_PASSWORD must be at least 32 characters."
    log_error "Reason: this value is used for both HONUA_ADMIN_PASSWORD and Security__ConnectionEncryption__MasterKey in Terraform app modules."
    exit 1
  fi
}

validate_boolean_flags() {
  validate_boolean_value "HONUA_AZURE_KEEP_DATA" "$KEEP_DATA"

  if [[ -n "$DESTROY_DATA" ]]; then
    validate_boolean_value "HONUA_AZURE_DESTROY_DATA" "$DESTROY_DATA"
  fi

  if [[ "$FUNCTIONS_SKIP_MIGRATIONS" != "true" && "$FUNCTIONS_SKIP_MIGRATIONS" != "false" ]]; then
    log_error "HONUA_AZURE_FUNCTIONS_SKIP_MIGRATIONS must be 'true' or 'false' (got '$FUNCTIONS_SKIP_MIGRATIONS')"
    exit 1
  fi
}

validate_boolean_value() {
  local name="$1"
  local value="$2"

  if [[ "$value" != "true" && "$value" != "false" ]]; then
    log_error "$name must be true or false"
    exit 1
  fi
}

normalize_identifiers() {
  ENVIRONMENT="$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
  NAME_PREFIX_BASE="$(echo "$NAME_PREFIX_BASE" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"

  if [[ -z "$ENVIRONMENT" || -z "$NAME_PREFIX_BASE" ]]; then
    log_error "Environment/name prefix became empty after normalization"
    exit 1
  fi

  NAME_PREFIX_BASE="${NAME_PREFIX_BASE:0:10}"
  DATA_NAME_PREFIX="${NAME_PREFIX_BASE}"
  ACA_NAME_PREFIX="${NAME_PREFIX_BASE}aca"
  FUNCTIONS_NAME_PREFIX="${NAME_PREFIX_BASE}fn"

  ACA_NAME_PREFIX="${ACA_NAME_PREFIX:0:20}"
  FUNCTIONS_NAME_PREFIX="${FUNCTIONS_NAME_PREFIX:0:20}"
}

apply_aot_mode() {
  if [[ "$USE_AOT" != "true" ]]; then
    return
  fi

  if [[ "$ACA_IMAGE" == "$DEFAULT_HONUA_IMAGE" ]]; then
    ACA_IMAGE="$DEFAULT_HONUA_AOT_IMAGE"
  fi

  if [[ "$FUNCTIONS_AOT_AUTOSWITCH" == "true" && "$FUNCTIONS_IMAGE" == "$DEFAULT_HONUA_FUNCTIONS_IMAGE" ]]; then
    FUNCTIONS_IMAGE="$DEFAULT_HONUA_FUNCTIONS_AOT_IMAGE"
  fi
}

validate_existing_resource_inputs() {
  if [[ -n "$EXISTING_DB_FQDN" && -z "$EXISTING_DB_CONNECTION_STRING" ]]; then
    log_error "--existing-db-connection is required when --existing-db-fqdn is provided"
    exit 1
  fi

  if [[ -z "$EXISTING_DB_FQDN" && -n "$EXISTING_DB_CONNECTION_STRING" ]]; then
    log_error "--existing-db-fqdn is required when --existing-db-connection is provided"
    exit 1
  fi
}

validate_existing_data_stack_availability() {
  local server_name=""
  local redis_name=""
  local redis_resource_group=""

  if ! has_existing_data_inputs; then
    return 0
  fi

  if [[ -z "$EXISTING_DB_RESOURCE_GROUP" && -n "$EXISTING_DB_FQDN" ]]; then
    EXISTING_DB_RESOURCE_GROUP="$(infer_existing_postgres_resource_group_from_db_fqdn "$EXISTING_DB_FQDN" 2>/dev/null || true)"
  fi

  if [[ -n "$EXISTING_DB_RESOURCE_GROUP" ]]; then
    server_name="${EXISTING_DB_FQDN%%.*}"
    if run_az postgres flexible-server show \
      --resource-group "$EXISTING_DB_RESOURCE_GROUP" \
      --name "$server_name" \
      --query "name" \
      -o tsv >/dev/null 2>&1; then
      return 0
    fi
  fi

  if [[ -n "$EXISTING_DB_FQDN" ]] && \
     redis_name="$(infer_existing_redis_name_from_db_fqdn "$EXISTING_DB_FQDN" 2>/dev/null || true)" && \
     redis_resource_group="$(infer_existing_redis_resource_group_from_db_fqdn "$EXISTING_DB_FQDN" 2>/dev/null || true)" && \
     [[ -n "$redis_name" ]] && [[ -n "$redis_resource_group" ]] && \
     run_az redis show \
       --resource-group "$redis_resource_group" \
       --name "$redis_name" \
       --query "name" \
       -o tsv >/dev/null 2>&1; then
    log_warn "Configured reused Azure DB stack is stale, but the paired Redis cache still exists; forcing a fresh Azure data stack seed"
  else
    log_warn "Configured reused Azure data stack is stale or no longer accessible; forcing a fresh Azure data stack seed"
  fi

  EXISTING_DB_FQDN=""
  EXISTING_DB_RESOURCE_GROUP=""
  EXISTING_DB_CONNECTION_STRING=""
  EXISTING_REDIS_CONNECTION_STRING=""
  AUTO_PROVISION_DATA_STACK=true
}

has_existing_data_inputs() {
  [[ -n "$EXISTING_DB_FQDN" &&
    -n "$EXISTING_DB_CONNECTION_STRING" &&
    -n "$EXISTING_REDIS_CONNECTION_STRING" ]]
}

cache_file_is_safe_to_read() {
  if [[ ! -f "$DATA_CACHE_FILE" ]]; then
    return 1
  fi

  if [[ -L "$DATA_CACHE_FILE" ]]; then
    log_warn "Ignoring Azure data cache file symlink: $DATA_CACHE_FILE"
    return 1
  fi

  if [[ ! -r "$DATA_CACHE_FILE" ]]; then
    log_warn "Ignoring unreadable Azure data cache file: $DATA_CACHE_FILE"
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
    log_info "Force-new-data-infra enabled; ignoring cached Azure data inputs"
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
      log_warn "Malformed Azure data cache file (missing '='): $DATA_CACHE_FILE"
      return
    fi

    key="${line%%=*}"
    value="${line#*=}"

    case "$key" in
      HONUA_CACHE_FORMAT)
        if [[ "$value" != "$DATA_CACHE_FORMAT" ]]; then
          log_warn "Unsupported Azure data cache format in $DATA_CACHE_FILE (expected $DATA_CACHE_FORMAT)"
          return
        fi
        format_seen=true
        ;;
      EXISTING_DB_FQDN|EXISTING_DB_RESOURCE_GROUP|EXISTING_DB_CONNECTION_STRING|EXISTING_REDIS_CONNECTION_STRING)
        if ! cache_decode_into_var "$key" "$value"; then
          log_warn "Failed decoding Azure data cache key '$key' in $DATA_CACHE_FILE"
          return
        fi
        ;;
      *)
        log_warn "Ignoring unexpected Azure data cache key '$key' in $DATA_CACHE_FILE"
        ;;
    esac
  done < "$DATA_CACHE_FILE"

  if [[ "$format_seen" != "true" ]]; then
    log_warn "Azure data cache file missing format marker; ignoring cache: $DATA_CACHE_FILE"
    return
  fi

  if has_existing_data_inputs; then
    log_info "Loaded Azure data reuse inputs from $DATA_CACHE_FILE"
  else
    log_warn "Data cache file exists but is incomplete: $DATA_CACHE_FILE"
  fi
}

persist_data_reuse_cache() {
  local cache_dir
  local tmp_file

  cache_dir="$(dirname "$DATA_CACHE_FILE")"
  mkdir -p "$cache_dir"

  tmp_file="$(mktemp "$cache_dir/honua-azure-data-cache.XXXXXX")"
  chmod 600 "$tmp_file"
  cat > "$tmp_file" <<EOF
HONUA_CACHE_FORMAT=$DATA_CACHE_FORMAT
EXISTING_DB_FQDN=$(cache_encode_value "$EXISTING_DB_FQDN")
EXISTING_DB_RESOURCE_GROUP=$(cache_encode_value "$EXISTING_DB_RESOURCE_GROUP")
EXISTING_DB_CONNECTION_STRING=$(cache_encode_value "$EXISTING_DB_CONNECTION_STRING")
EXISTING_REDIS_CONNECTION_STRING=$(cache_encode_value "$EXISTING_REDIS_CONNECTION_STRING")
EOF
  mv "$tmp_file" "$DATA_CACHE_FILE"

  log_info "Saved Azure data reuse inputs to $DATA_CACHE_FILE"
}

clear_data_reuse_cache() {
  if [[ -f "$DATA_CACHE_FILE" ]]; then
    rm -f "$DATA_CACHE_FILE"
    log_info "Cleared Azure data reuse cache: $DATA_CACHE_FILE"
  fi
}

configure_data_stack_mode() {
  resolve_data_retention_mode

  if [[ "$FORCE_NEW_DATA_INFRA" == "true" ]]; then
    EXISTING_DB_FQDN=""
    EXISTING_DB_RESOURCE_GROUP=""
    EXISTING_DB_CONNECTION_STRING=""
    EXISTING_REDIS_CONNECTION_STRING=""
    AUTO_PROVISION_DATA_STACK=true
    log_info "Force-new-data-infra enabled; provisioning a fresh Azure data stack"
    return
  fi

  if [[ -z "$EXISTING_DB_CONNECTION_STRING" && -z "$EXISTING_REDIS_CONNECTION_STRING" ]]; then
    AUTO_PROVISION_DATA_STACK=true
    return
  fi

  AUTO_PROVISION_DATA_STACK=false

  if [[ -n "$EXISTING_DB_CONNECTION_STRING" && -n "$EXISTING_REDIS_CONNECTION_STRING" ]]; then
    log_info "Using caller-provided DB/Redis connections; skipping azure-data bootstrap stack"
    return
  fi

  log_warn "Partial existing data inputs detected; skipping azure-data bootstrap stack and using mixed data wiring"
}

resolve_data_retention_mode() {
  if [[ "$DESTROY_DATA_MODE_EXPLICIT" == "true" ]]; then
    return
  fi

  if [[ "$KEEP_DATA" == "true" ]]; then
    DESTROY_DATA=false
    return
  fi

  if [[ -n "$DESTROY_DATA" ]]; then
    return
  fi

  DESTROY_DATA=true
}
