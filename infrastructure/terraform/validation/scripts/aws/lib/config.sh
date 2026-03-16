# Sourced by validation.sh after common globals,
# logging helpers, and shared post-apply validation helpers are defined.

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

ensure_existing_db_connection_string_shape() {
  local normalized=""

  if [[ -z "$EXISTING_DB_CONNECTION_STRING" ]]; then
    return 0
  fi

  normalized="$(normalize_existing_db_connection_string "$EXISTING_DB_CONNECTION_STRING")"

  if [[ "$normalized" != "$EXISTING_DB_CONNECTION_STRING" ]]; then
    log_info "Normalized reused AWS DB connection string before Terraform apply"
    EXISTING_DB_CONNECTION_STRING="$normalized"
  fi

  if [[ "$EXISTING_DB_CONNECTION_STRING" != *=* ]]; then
    if [[ -n "$EXISTING_DB_ENDPOINT" ]]; then
      log_warn "Reused AWS DB connection string was not ADO.NET-shaped; rebuilding from existing DB endpoint and validation defaults"
      EXISTING_DB_CONNECTION_STRING="Host=${EXISTING_DB_ENDPOINT};Port=5432;Database=honua;Username=honua;Password=${HONUA_DB_PASSWORD};SSL Mode=Require;Trust Server Certificate=false"
      return 0
    fi

    log_error "Reused AWS DB connection string is not a valid ADO.NET connection string and no existing DB endpoint fallback is available"
    exit 1
  fi
}

ensure_existing_redis_connection_string_shape() {
  local normalized=""

  if [[ -z "$EXISTING_REDIS_CONNECTION_STRING" ]]; then
    return 0
  fi

  normalized="$(printf '%s' "$EXISTING_REDIS_CONNECTION_STRING" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  if [[ "$normalized" == \"*\" && "$normalized" == *\" ]]; then
    normalized="${normalized:1:${#normalized}-2}"
  fi

  if [[ "$normalized" == \'*\' && "$normalized" == *\' ]]; then
    normalized="${normalized:1:${#normalized}-2}"
  fi

  if [[ "$normalized" != "$EXISTING_REDIS_CONNECTION_STRING" ]]; then
    log_info "Normalized reused AWS Redis connection string before Terraform apply"
    EXISTING_REDIS_CONNECTION_STRING="$normalized"
  fi

  if [[ "$EXISTING_REDIS_CONNECTION_STRING" == *","* && "$EXISTING_REDIS_CONNECTION_STRING" == *"password="* && "$EXISTING_REDIS_CONNECTION_STRING" != -* ]]; then
    return 0
  fi

  log_error "Reused AWS Redis connection string is invalid. Expected '<host>:6379,password=...,ssl=true'."
  exit 1
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

validate_boolean_value() {
  local name="$1"
  local value="$2"

  if [[ "$value" != "true" && "$value" != "false" ]]; then
    log_error "$name must be true or false"
    exit 1
  fi
}

resolve_data_retention_mode() {
  validate_boolean_value "HONUA_AWS_KEEP_DATA" "$KEEP_DATA"

  if [[ -n "$DESTROY_DATA" ]]; then
    validate_boolean_value "HONUA_AWS_DESTROY_DATA" "$DESTROY_DATA"
  fi

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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack)
        STACK="$2"
        shift 2
        ;;
      --region)
        REGION="$2"
        shift 2
        ;;
      --environment)
        ENVIRONMENT="$2"
        shift 2
        ;;
      --name-prefix-base)
        NAME_PREFIX_BASE="$2"
        shift 2
        ;;
      --aot)
        USE_AOT=true
        shift
        ;;
      --ecs-image)
        ECS_IMAGE="$2"
        shift 2
        ;;
      --ecs-canary-enabled)
        ECS_CANARY_ENABLED=true
        shift
        ;;
      --ecs-canary-image)
        ECS_CANARY_IMAGE="$2"
        shift 2
        ;;
      --ecs-canary-desired-count)
        ECS_CANARY_DESIRED_COUNT="$2"
        shift 2
        ;;
      --ecs-canary-weight)
        ECS_CANARY_WEIGHT_PERCENTAGE="$2"
        shift 2
        ;;
      --ecs-canary-header-name)
        ECS_CANARY_HEADER_NAME="$2"
        shift 2
        ;;
      --ecs-canary-header-value)
        ECS_CANARY_HEADER_VALUE="$2"
        shift 2
        ;;
      --serverless-image)
        SERVERLESS_IMAGE="$2"
        shift 2
        ;;
      --ecs-previous-image)
        ECS_PREVIOUS_IMAGE="$2"
        shift 2
        ;;
      --serverless-previous-image)
        SERVERLESS_PREVIOUS_IMAGE="$2"
        shift 2
        ;;
      --upgrade-rollback)
        RUN_UPGRADE_ROLLBACK=true
        shift
        ;;
      --db-ingress-cidr)
        DB_INGRESS_CIDR="$2"
        shift 2
        ;;
      --http-ingress-cidr)
        HTTP_INGRESS_CIDR="$2"
        shift 2
        ;;
      --existing-db-endpoint)
        EXISTING_DB_ENDPOINT="$2"
        shift 2
        ;;
      --existing-db-connection)
        EXISTING_DB_CONNECTION_STRING="$2"
        shift 2
        ;;
      --existing-redis-connection)
        EXISTING_REDIS_CONNECTION_STRING="$2"
        shift 2
        ;;
      --existing-vpc-id)
        EXISTING_VPC_ID="$2"
        shift 2
        ;;
      --existing-vpc-cidr)
        EXISTING_VPC_CIDR="$2"
        shift 2
        ;;
      --existing-public-subnets)
        EXISTING_PUBLIC_SUBNET_IDS="$2"
        shift 2
        ;;
      --existing-private-subnets)
        EXISTING_PRIVATE_SUBNET_IDS="$2"
        shift 2
        ;;
      --timeout-seconds)
        TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --max-ready-seconds)
        READY_SLO_SECONDS="$2"
        shift 2
        ;;
      --max-load-error-rate)
        MAX_LOAD_ERROR_RATE_PERCENT="$2"
        shift 2
        ;;
      --max-run-cost-usd)
        MAX_RUN_COST_USD="$2"
        shift 2
        ;;
      --plan-artifact-dir)
        PLAN_ARTIFACT_DIR="$2"
        shift 2
        ;;
      --allow-destroy-plan)
        ALLOW_DESTROY_PLAN=true
        shift
        ;;
      --ttl-hours)
        TTL_HOURS="$2"
        shift 2
        ;;
      --skip-quota-preflight)
        RUN_QUOTA_PREFLIGHT=false
        shift
        ;;
      --skip-idempotency)
        CHECK_IDEMPOTENCY=false
        shift
        ;;
      --skip-protocol-checks)
        CHECK_PROTOCOLS=false
        shift
        ;;
      --skip-db-resilience)
        RUN_DB_RESILIENCE=false
        shift
        ;;
      --no-scale-check)
        QUICK_SCALE=false
        shift
        ;;
      --destroy-data)
        DESTROY_DATA=true
        DESTROY_DATA_MODE_EXPLICIT=true
        shift
        ;;
      --keep-data)
        DESTROY_DATA=false
        DESTROY_DATA_MODE_EXPLICIT=true
        shift
        ;;
      --force-new-data-infra)
        FORCE_NEW_DATA_INFRA=true
        shift
        ;;
      --force-new-data)
        log_warn "--force-new-data is deprecated; use --force-new-data-infra"
        FORCE_NEW_DATA_INFRA=true
        shift
        ;;
      --no-destroy)
        AUTO_DESTROY=false
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ "$STACK" != "data" && "$STACK" != "ecs" && "$STACK" != "serverless" && "$STACK" != "both" ]]; then
    log_error "Invalid --stack value: $STACK"
    exit 1
  fi
}

apply_aot_mode() {
  if [[ "$USE_AOT" != "true" ]]; then
    return
  fi

  if [[ -n "$ECS_IMAGE" && "$ECS_IMAGE" == *:* ]]; then
    local ecs_tag
    ecs_tag="${ECS_IMAGE##*:}"
    if [[ "$ecs_tag" == *"$DEFAULT_ECS_TAG_SUFFIX" && "$ecs_tag" != *"$DEFAULT_ECS_AOT_TAG_SUFFIX" ]]; then
      ECS_IMAGE="${ECS_IMAGE%:*}:${ecs_tag}-aot"
    fi
  elif [[ "$ECS_IMAGE" == "$DEFAULT_HONUA_IMAGE" ]]; then
    ECS_IMAGE="$DEFAULT_HONUA_AOT_IMAGE"
  fi

  if [[ -n "$SERVERLESS_IMAGE" && "$SERVERLESS_IMAGE" == *:* ]]; then
    local serverless_tag
    serverless_tag="${SERVERLESS_IMAGE##*:}"
    if [[ "$serverless_tag" == *"$DEFAULT_LAMBDA_TAG_SUFFIX" && "$serverless_tag" != *"$DEFAULT_LAMBDA_AOT_TAG_SUFFIX" ]]; then
      SERVERLESS_IMAGE="${SERVERLESS_IMAGE%:*}:${serverless_tag}-aot"
    fi
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
  ECS_NAME_PREFIX="${NAME_PREFIX_BASE}ecs"
  SERVERLESS_NAME_PREFIX="${NAME_PREFIX_BASE}sl"
  DATA_NAME_PREFIX="${NAME_PREFIX_BASE}data"
}
