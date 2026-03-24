#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=""
SEARCH_DIR="$SCRIPT_DIR"
while [[ "$SEARCH_DIR" != "/" ]]; do
  if [[ -f "$SEARCH_DIR/Honua.sln" ]]; then
    REPO_ROOT="$SEARCH_DIR"
    break
  fi
  SEARCH_DIR="$(dirname "$SEARCH_DIR")"
done

if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
fi

if [[ -z "$REPO_ROOT" ]]; then
  echo "[ERROR] Could not determine repository root from $SCRIPT_DIR" >&2
  exit 1
fi

STACK="both"
REGION="${AWS_REGION_OVERRIDE:-us-east-1}"
ENVIRONMENT="${AWS_TF_ENVIRONMENT:-it}"
NAME_PREFIX_BASE="${AWS_TF_NAME_PREFIX_BASE:-h$(date -u +%m%d%H%M)$((RANDOM % 10))}"
DEFAULT_HONUA_IMAGE="ghcr.io/honua-io/honua-server:latest"
DEFAULT_HONUA_AOT_IMAGE="ghcr.io/honua-io/honua-server:latest-aot"
DEFAULT_ECS_TAG_SUFFIX="-ecs"
DEFAULT_ECS_AOT_TAG_SUFFIX="-ecs-aot"
DEFAULT_LAMBDA_TAG_SUFFIX="-lambda"
DEFAULT_LAMBDA_AOT_TAG_SUFFIX="-lambda-aot"
USE_AOT="${HONUA_USE_AOT:-false}"
ECS_IMAGE="${HONUA_AWS_ECS_IMAGE:-}"
SERVERLESS_IMAGE="${HONUA_AWS_SERVERLESS_IMAGE:-}"
ECS_PREVIOUS_IMAGE="${HONUA_AWS_ECS_PREVIOUS_IMAGE:-}"
SERVERLESS_PREVIOUS_IMAGE="${HONUA_AWS_SERVERLESS_PREVIOUS_IMAGE:-}"
ECS_CANARY_ENABLED="${HONUA_AWS_ECS_CANARY_ENABLED:-false}"
ECS_CANARY_IMAGE="${HONUA_AWS_ECS_CANARY_IMAGE:-}"
ECS_CANARY_DESIRED_COUNT="${HONUA_AWS_ECS_CANARY_DESIRED_COUNT:-1}"
ECS_CANARY_WEIGHT_PERCENTAGE="${HONUA_AWS_ECS_CANARY_WEIGHT_PERCENTAGE:-0}"
ECS_CANARY_HEADER_NAME="${HONUA_AWS_ECS_CANARY_HEADER_NAME:-X-Honua-Canary}"
ECS_CANARY_HEADER_VALUE="${HONUA_AWS_ECS_CANARY_HEADER_VALUE:-always}"
AUTO_DESTROY=true
DESTROY_DATA="${HONUA_AWS_DESTROY_DATA:-}"
DESTROY_DATA_MODE_EXPLICIT=false
KEEP_DATA="${HONUA_AWS_KEEP_DATA:-false}"
QUICK_SCALE=true
CHECK_IDEMPOTENCY=true
CHECK_PROTOCOLS=true
RUN_DB_RESILIENCE=true
RUN_UPGRADE_ROLLBACK=false
RUN_QUOTA_PREFLIGHT=true
TIMEOUT_SECONDS="${HONUA_AWS_TEST_TIMEOUT_SECONDS:-900}"
LOAD_REQUESTS="${HONUA_AWS_LOAD_REQUESTS:-120}"
LOAD_CONCURRENCY="${HONUA_AWS_LOAD_CONCURRENCY:-20}"
ECS_DESIRED_COUNT=1
ECS_SCALE_TARGET_DESIRED_COUNT=2
READY_SLO_SECONDS="${HONUA_READY_SLO_SECONDS:-600}"
MAX_LOAD_ERROR_RATE_PERCENT="${HONUA_MAX_LOAD_ERROR_RATE_PERCENT:-0}"
MAX_RUN_COST_USD="${HONUA_MAX_RUN_COST_USD:-0}"
DB_INGRESS_CIDR="${HONUA_AWS_DB_INGRESS_CIDR:-}"
HTTP_INGRESS_CIDR="${HONUA_AWS_HTTP_INGRESS_CIDR:-}"
EXISTING_DB_ENDPOINT="${HONUA_AWS_EXISTING_DB_ENDPOINT:-}"
EXISTING_DB_CONNECTION_STRING="${HONUA_AWS_EXISTING_DB_CONNECTION_STRING:-}"
EXISTING_REDIS_CONNECTION_STRING="${HONUA_AWS_EXISTING_REDIS_CONNECTION_STRING:-}"
EXISTING_VPC_ID="${HONUA_AWS_EXISTING_VPC_ID:-}"
EXISTING_VPC_CIDR="${HONUA_AWS_EXISTING_VPC_CIDR:-}"
EXISTING_PUBLIC_SUBNET_IDS="${HONUA_AWS_EXISTING_PUBLIC_SUBNET_IDS:-}"
EXISTING_PRIVATE_SUBNET_IDS="${HONUA_AWS_EXISTING_PRIVATE_SUBNET_IDS:-}"
POSTGIS_READINESS_MAX_ATTEMPTS="${HONUA_AWS_POSTGIS_READINESS_MAX_ATTEMPTS:-120}"
POSTGIS_READINESS_SLEEP_SECONDS="${HONUA_AWS_POSTGIS_READINESS_SLEEP_SECONDS:-10}"
TF_IMAGE="${HONUA_TERRAFORM_IMAGE:-honua-terraform-psql:1.8.5}"
AWS_CLI_IMAGE="${HONUA_AWS_CLI_IMAGE:-amazon/aws-cli:2.17.61}"
PLAN_ARTIFACT_DIR="${HONUA_TF_PLAN_ARTIFACT_DIR:-}"
ALLOW_DESTROY_PLAN="${HONUA_ALLOW_DESTROY_PLAN:-false}"
TTL_HOURS="${HONUA_TTL_HOURS:-8}"
VALIDATION_RUN_ID="${HONUA_VALIDATION_RUN_ID:-aws-$(date -u +%Y%m%d%H%M%S)}"
FORCE_DOCKER_TF="${HONUA_FORCE_DOCKER_TF:-false}"
FORCE_DOCKER_PG_TOOLS="${HONUA_FORCE_DOCKER_PG_TOOLS:-false}"
DATA_CACHE_FILE="${HONUA_AWS_DATA_CACHE_FILE:-/tmp/honua-aws-data-reuse.env}"
DATA_CACHE_FORMAT="v2-base64"
FORCE_NEW_DATA_INFRA="${HONUA_AWS_FORCE_NEW_DATA_INFRA:-${HONUA_AWS_FORCE_NEW_DATA:-false}}"
AUTO_REPAIR_VPC_EGRESS="${HONUA_AWS_AUTO_REPAIR_VPC_EGRESS:-true}"

TEMP_TF_ROOT=""
ECS_APPLIED=false
SERVERLESS_APPLIED=false
DATA_APPLIED=false
DATA_CREATED=false

ECS_NAME_PREFIX=""
SERVERLESS_NAME_PREFIX=""
DATA_NAME_PREFIX=""
EXPIRES_AT_UTC=""
DB_PASSWORD_EFFECTIVE=""
USE_DOCKER_TF=false
USE_DOCKER_AWS_CLI=false
USE_DOCKER_PG_TOOLS=false
declare -a EXISTING_DB_RUNNER_INGRESS_GROUP_IDS=()

usage() {
  cat <<USAGE
Run live Terraform integration tests for AWS data, ECS, and AWS serverless.

Usage:
  ./infrastructure/terraform/validation/scripts/aws/run-aws-terraform-integration.sh [options]

Options:
  --stack <data|ecs|serverless|both>   Stack to test (default: both)
  --region <aws-region>                AWS region (default: us-east-1)
  --environment <name>                 Environment suffix in names (default: it)
  --name-prefix-base <prefix>          Base prefix for generated resource names
  --aot                                Map ECS tag '*-ecs' -> '*-ecs-aot' and serverless tag '*-lambda' -> '*-lambda-aot' when provided (JIT is debug fallback)
  --ecs-image <image>                  ECS container image
  --ecs-canary-enabled                 Enable the optional ECS ALB canary service
  --ecs-canary-image <image>           Optional canary ECS image (defaults to --ecs-image)
  --ecs-canary-desired-count <n>       Desired task count for the ECS canary service (default: 1)
  --ecs-canary-weight <percent>        Default ALB traffic percentage routed to canary (default: 0)
  --ecs-canary-header-name <name>      Header name used to route requests directly to canary
  --ecs-canary-header-value <value>    Header value used to route requests directly to canary
  --serverless-image <ecr-uri>         Lambda container image URI (ECR)
  --ecs-previous-image <image>         Previous ECS image for upgrade/rollback validation
  --serverless-previous-image <image>  Previous serverless image for upgrade/rollback validation
  --upgrade-rollback                   Enable upgrade/rollback validation sequence
  --db-ingress-cidr <cidr>             CIDR allowed to reach RDS for PostGIS enablement
  --http-ingress-cidr <cidr>           CIDR allowed to reach the ECS ALB over HTTP during validation
  --existing-db-endpoint <endpoint>    Reuse existing PostgreSQL endpoint
  --existing-db-connection <string>    Reuse existing PostgreSQL connection string
  --existing-redis-connection <str>    Reuse existing Redis connection string
  --existing-vpc-id <vpc-id>           Reuse existing VPC ID
  --existing-vpc-cidr <cidr>           CIDR for existing VPC
  --existing-public-subnets <json>     JSON list of existing public subnet IDs
  --existing-private-subnets <json>    JSON list of existing private subnet IDs
  --timeout-seconds <n>                Health wait timeout per stack (default: 900)
  --max-ready-seconds <n>              Ready SLO threshold (default: 600)
  --max-load-error-rate <percent>      Max allowed load error rate (default: 0)
  --max-run-cost-usd <n>               Max allowed estimated run cost (0 disables cap)
  --plan-artifact-dir <path>           Directory to persist plan artifacts
  --allow-destroy-plan                 Allow plans containing resource destroys
  --ttl-hours <n>                      TTL tag value for provisioned resources (default: 8)
  --skip-quota-preflight               Skip AWS quota preflight checks
  --skip-idempotency                   Skip post-apply zero-drift plan assertion
  --skip-protocol-checks               Skip REST/OGC/OData/admin auth + admin CRUD/query smoke checks
  --skip-db-resilience                 Skip DB backup/restore drill
  --no-scale-check                     Skip quick ECS scale check
  --destroy-data                       Destroy auto-created data stack during cleanup (default)
  --keep-data                          Keep auto-created data stack for reuse and enable local cache reuse
  --force-new-data-infra               Ignore cached/existing data inputs and create a fresh data stack
  --force-new-data                     Deprecated alias for --force-new-data-infra
  --no-destroy                         Keep resources after test run
  --help, -h                           Show this help

Required environment variables:
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  HONUA_ADMIN_PASSWORD (at least 32 chars)
  HONUA_DB_PASSWORD
  HONUA_AWS_ECS_IMAGE (when --stack ecs|both)
  HONUA_AWS_ECS_CANARY_ENABLED
  HONUA_AWS_ECS_CANARY_IMAGE
  HONUA_AWS_ECS_CANARY_DESIRED_COUNT
  HONUA_AWS_ECS_CANARY_WEIGHT_PERCENTAGE
  HONUA_AWS_ECS_CANARY_HEADER_NAME
  HONUA_AWS_ECS_CANARY_HEADER_VALUE
  HONUA_AWS_SERVERLESS_IMAGE (when --stack serverless|both)

Optional environment variables:
  AWS_SESSION_TOKEN
  HONUA_AWS_EXISTING_DB_ENDPOINT
  HONUA_AWS_EXISTING_DB_CONNECTION_STRING
  HONUA_AWS_EXISTING_REDIS_CONNECTION_STRING
  HONUA_AWS_HTTP_INGRESS_CIDR
  HONUA_AWS_EXISTING_VPC_ID
  HONUA_AWS_EXISTING_VPC_CIDR
  HONUA_AWS_EXISTING_PUBLIC_SUBNET_IDS
  HONUA_AWS_EXISTING_PRIVATE_SUBNET_IDS
  HONUA_AWS_KEEP_DATA
  HONUA_AWS_DESTROY_DATA
  HONUA_AWS_DATA_CACHE_FILE
  HONUA_AWS_FORCE_NEW_DATA_INFRA
  HONUA_AWS_AUTO_REPAIR_VPC_EGRESS
  HONUA_AWS_POSTGIS_READINESS_MAX_ATTEMPTS
  HONUA_AWS_POSTGIS_READINESS_SLEEP_SECONDS
  HONUA_PLATFORM_VALIDATION_SCRIPT
USAGE
}

log_info() {
  echo "[INFO] $1"
}

log_warn() {
  echo "[WARN] $1"
}

log_error() {
  echo "[ERROR] $1" >&2
}

source "$SCRIPT_DIR/../shared/platform-post-apply-validation.sh"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "Required command not found: $1"
    exit 1
  fi
}

require_env() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      log_error "Missing required environment variable: $name"
      exit 1
    fi
  done
}

validate_requested_images() {
  if [[ "$STACK" == "ecs" || "$STACK" == "both" ]]; then
    if [[ -z "$ECS_IMAGE" ]]; then
      log_error "ECS image is required. Set HONUA_AWS_ECS_IMAGE or pass --ecs-image."
      exit 1
    fi

    if [[ "$RUN_UPGRADE_ROLLBACK" == "true" && -z "$ECS_PREVIOUS_IMAGE" ]]; then
      log_error "ECS upgrade/rollback requires HONUA_AWS_ECS_PREVIOUS_IMAGE or --ecs-previous-image."
      exit 1
    fi
  fi

  if [[ "$STACK" == "serverless" || "$STACK" == "both" ]]; then
    if [[ -z "$SERVERLESS_IMAGE" ]]; then
      log_error "Serverless image is required. Set HONUA_AWS_SERVERLESS_IMAGE or pass --serverless-image."
      exit 1
    fi

    if [[ "$RUN_UPGRADE_ROLLBACK" == "true" && -z "$SERVERLESS_PREVIOUS_IMAGE" ]]; then
      log_error "Serverless upgrade/rollback requires HONUA_AWS_SERVERLESS_PREVIOUS_IMAGE or --serverless-previous-image."
      exit 1
    fi
  fi
}

validate_ecs_canary_inputs() {
  if [[ "$ECS_CANARY_ENABLED" != "true" && "$ECS_CANARY_ENABLED" != "false" ]]; then
    log_error "ECS canary flag must be true or false"
    exit 1
  fi

  if ! [[ "$ECS_CANARY_DESIRED_COUNT" =~ ^[0-9]+$ ]] || (( ECS_CANARY_DESIRED_COUNT < 1 )); then
    log_error "ECS canary desired count must be an integer >= 1"
    exit 1
  fi

  if ! [[ "$ECS_CANARY_WEIGHT_PERCENTAGE" =~ ^[0-9]+$ ]] || (( ECS_CANARY_WEIGHT_PERCENTAGE < 0 || ECS_CANARY_WEIGHT_PERCENTAGE > 100 )); then
    log_error "ECS canary weight must be an integer between 0 and 100"
    exit 1
  fi

  if [[ "$ECS_CANARY_ENABLED" != "true" && "$ECS_CANARY_WEIGHT_PERCENTAGE" != "0" ]]; then
    log_error "ECS canary weight must be 0 unless --ecs-canary-enabled is set"
    exit 1
  fi

  if [[ -z "$ECS_CANARY_HEADER_NAME" || -z "$ECS_CANARY_HEADER_VALUE" ]]; then
    log_error "ECS canary header name and value must both be non-empty"
    exit 1
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

aws_secret_string() {
  local secret_id="$1"

  if [[ -z "$secret_id" || "$secret_id" == "null" ]]; then
    log_error "AWS secret reference was empty"
    return 1
  fi

  run_aws secretsmanager get-secret-value --secret-id "$secret_id" --query 'SecretString' --output text
}

existing_db_security_group_ids() {
  local group_ids

  group_ids="$(run_aws rds describe-db-instances \
    --query "DBInstances[?Endpoint.Address=='${EXISTING_DB_ENDPOINT}'].VpcSecurityGroups[].VpcSecurityGroupId" \
    --output text)"

  if [[ -z "$group_ids" || "$group_ids" == "None" ]]; then
    log_error "Could not resolve RDS security groups for reused DB endpoint $EXISTING_DB_ENDPOINT"
    return 1
  fi

  printf '%s\n' "$group_ids" | tr '\t' '\n' | sed '/^$/d'
}

security_group_allows_db_cidr() {
  local group_id="$1"
  local cidr="$2"
  local cidrs

  cidrs="$(run_aws ec2 describe-security-groups \
    --group-ids "$group_id" \
    --query "SecurityGroups[0].IpPermissions[?IpProtocol=='tcp' && FromPort==\`5432\` && ToPort==\`5432\`].IpRanges[].CidrIp" \
    --output text)"

  if [[ -z "$cidrs" || "$cidrs" == "None" ]]; then
    return 1
  fi

  printf '%s\n' "$cidrs" | tr '\t' '\n' | grep -Fxq "$cidr"
}

authorize_existing_db_runner_ingress() {
  local group_id=""

  if ! has_existing_data_inputs; then
    return 0
  fi

  if [[ -z "$DB_INGRESS_CIDR" ]]; then
    log_error "Runner DB ingress CIDR was empty while reusing AWS data"
    return 1
  fi

  while IFS= read -r group_id; do
    [[ -z "$group_id" ]] && continue

    if security_group_allows_db_cidr "$group_id" "$DB_INGRESS_CIDR"; then
      log_info "Reused RDS security group $group_id already allows $DB_INGRESS_CIDR"
      continue
    fi

    run_aws ec2 authorize-security-group-ingress \
      --group-id "$group_id" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":5432,\"ToPort\":5432,\"IpRanges\":[{\"CidrIp\":\"$DB_INGRESS_CIDR\",\"Description\":\"Honua validation runner ${VALIDATION_RUN_ID}\"}]}]" >/dev/null
    EXISTING_DB_RUNNER_INGRESS_GROUP_IDS+=("$group_id")
    log_info "Authorized temporary RDS ingress from $DB_INGRESS_CIDR on security group $group_id"
  done < <(existing_db_security_group_ids)
}

revoke_existing_db_runner_ingress() {
  local group_id=""

  if [[ "${#EXISTING_DB_RUNNER_INGRESS_GROUP_IDS[@]}" -eq 0 ]]; then
    return 0
  fi

  for group_id in "${EXISTING_DB_RUNNER_INGRESS_GROUP_IDS[@]}"; do
    if ! run_aws ec2 revoke-security-group-ingress \
      --group-id "$group_id" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":5432,\"ToPort\":5432,\"IpRanges\":[{\"CidrIp\":\"$DB_INGRESS_CIDR\"}]}]" >/dev/null 2>&1; then
      log_warn "Failed to revoke temporary RDS ingress from $DB_INGRESS_CIDR on security group $group_id"
      return 1
    fi
    log_info "Revoked temporary RDS ingress from $DB_INGRESS_CIDR on security group $group_id"
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
  run_tf_apply_with_auth_retry "$root" "$plan_file"
  invalidate_terraform_output_json_cache "$root"
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

normalize_base_url() {
  local base_url="${1%/}"
  if [[ "$base_url" =~ ^https?:// ]]; then
    printf '%s\n' "$base_url"
    return
  fi

  printf 'https://%s\n' "$base_url"
}

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
      if ! curl -fsSL --max-time 20 "$target_url" >/dev/null; then
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

    endpoint_status="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 20 "$endpoint" || true)"
    if [[ "$endpoint_status" == 2* || "$endpoint_status" == 3* ]]; then
      return 0
    fi

    if [[ "$endpoint_status" == "401" || "$endpoint_status" == "403" ]]; then
      curl -fsSL --max-time 20 \
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

    endpoint_status="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 20 "$endpoint" || true)"
    if [[ "$endpoint_status" == 2* || "$endpoint_status" == 3* ]]; then
      return 0
    fi

    if [[ "$endpoint_status" == "401" || "$endpoint_status" == "403" ]]; then
      curl -fsSL --max-time 20 \
        -H "X-API-Key: $admin_api_key" \
        "$endpoint" >/dev/null
      return 0
    fi

    if [[ "$endpoint_status" == "404" ]]; then
      endpoint_body="$(curl -sS --max-time 20 "$endpoint" || true)"
      if [[ "$endpoint_body" == *"OData is not enabled for any available service."* ]]; then
        log_info "OData endpoint reachable with empty catalog: $endpoint returned HTTP 404"
        return 0
      fi
    fi

    log_error "Protocol smoke endpoint failed: $endpoint returned HTTP $endpoint_status"
    return 1
  }

  check_endpoint "${normalized}/rest/services?f=pjson"
  check_endpoint "${normalized}/ogc/features"
  check_odata_endpoint "${normalized}/odata"

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
        curl -sSL --max-time 20 -X DELETE \
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

  create_connection_response="$(curl -fsSL --max-time 20 -X POST \
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

  publish_layer_response="$(curl -fsSL --max-time 20 -X POST \
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
  query_response="$(curl -fsSL --max-time 20 \
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

verify_postgis_extensions() {
  local db_endpoint="$1"
  local extensions

  if [[ "$USE_DOCKER_PG_TOOLS" == "true" ]]; then
    extensions="$(docker run --rm \
      -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
      postgres:16-alpine \
      sh -c "psql '$(pg_conn "$db_endpoint" "honua")' -v ON_ERROR_STOP=1 -tA -c \"SELECT extname FROM pg_extension WHERE extname IN ('postgis','postgis_raster') ORDER BY extname;\"" || true)"
  else
    extensions="$(PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
      psql "$(pg_conn "$db_endpoint" "honua")" -v ON_ERROR_STOP=1 -tA -c "SELECT extname FROM pg_extension WHERE extname IN ('postgis','postgis_raster') ORDER BY extname;" || true)"
  fi

  if [[ "$extensions" != *"postgis"* || "$extensions" != *"postgis_raster"* ]]; then
    log_error "Expected postgis + postgis_raster extensions not both present on $db_endpoint"
    log_error "Observed extensions output: ${extensions:-<none>}"
    return 1
  fi

  log_info "Verified extensions on $db_endpoint: postgis + postgis_raster"
}

verify_db_backup_restore() {
  local db_endpoint="$1"
  local extensions_count=""
  local restored_table_count=""
  local dump_file
  local drill_log

  dump_file="$(mktemp)"
  drill_log="$(mktemp)"

  run_restore_drill_local() {
    PGPASSWORD="$DB_PASSWORD_EFFECTIVE" pg_dump "$(pg_conn "$db_endpoint" "honua")" -Fc -f "$dump_file"
    PGPASSWORD="$DB_PASSWORD_EFFECTIVE" psql "$(pg_conn "$db_endpoint" "postgres")" -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS honua_restore_check' >/dev/null
    PGPASSWORD="$DB_PASSWORD_EFFECTIVE" psql "$(pg_conn "$db_endpoint" "postgres")" -v ON_ERROR_STOP=1 -c 'CREATE DATABASE honua_restore_check' >/dev/null
    PGPASSWORD="$DB_PASSWORD_EFFECTIVE" pg_restore --no-owner --no-privileges -d "$(pg_conn "$db_endpoint" "honua_restore_check")" "$dump_file" >/dev/null
    restored_table_count="$(PGPASSWORD="$DB_PASSWORD_EFFECTIVE" psql "$(pg_conn "$db_endpoint" "honua_restore_check")" -tA -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema IN ('public','honua') AND table_type='BASE TABLE';" | tr -d '[:space:]')"
    extensions_count="$(PGPASSWORD="$DB_PASSWORD_EFFECTIVE" psql "$(pg_conn "$db_endpoint" "honua_restore_check")" -tA -c "SELECT COUNT(*) FROM pg_extension WHERE extname IN ('postgis','postgis_raster');" | tr -d '[:space:]')"
    if [[ "$extensions_count" != "2" ]]; then
      PGPASSWORD="$DB_PASSWORD_EFFECTIVE" psql "$(pg_conn "$db_endpoint" "honua_restore_check")" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS postgis_raster;" >/dev/null
      extensions_count="$(PGPASSWORD="$DB_PASSWORD_EFFECTIVE" psql "$(pg_conn "$db_endpoint" "honua_restore_check")" -tA -c "SELECT COUNT(*) FROM pg_extension WHERE extname IN ('postgis','postgis_raster');" | tr -d '[:space:]')"
    fi
    PGPASSWORD="$DB_PASSWORD_EFFECTIVE" psql "$(pg_conn "$db_endpoint" "postgres")" -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS honua_restore_check' >/dev/null
  }

  run_restore_drill_docker() {
    docker run --rm \
      -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
      -v "$dump_file:/tmp/honua.dump" \
      postgres:16-alpine \
      sh -c "set -e; \
        pg_dump '$(pg_conn "$db_endpoint" "honua")' -Fc -f /tmp/honua.dump; \
        psql '$(pg_conn "$db_endpoint" "postgres")' -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS honua_restore_check'; \
        psql '$(pg_conn "$db_endpoint" "postgres")' -v ON_ERROR_STOP=1 -c 'CREATE DATABASE honua_restore_check'; \
        pg_restore --no-owner --no-privileges -d '$(pg_conn "$db_endpoint" "honua_restore_check")' /tmp/honua.dump >/dev/null;" >/dev/null

    restored_table_count="$(docker run --rm \
      -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
      postgres:16-alpine \
      sh -c "psql '$(pg_conn "$db_endpoint" "honua_restore_check")' -tA -c \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema IN ('public','honua') AND table_type='BASE TABLE';\"" | tr -d '[:space:]')"

    extensions_count="$(docker run --rm \
      -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
      postgres:16-alpine \
      sh -c "psql '$(pg_conn "$db_endpoint" "honua_restore_check")' -tA -c \"SELECT COUNT(*) FROM pg_extension WHERE extname IN ('postgis','postgis_raster');\"" | tr -d '[:space:]')"
    if [[ "$extensions_count" != "2" ]]; then
      docker run --rm \
        -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
        postgres:16-alpine \
        sh -c "psql '$(pg_conn "$db_endpoint" "honua_restore_check")' -v ON_ERROR_STOP=1 -c \"CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS postgis_raster;\"" >/dev/null
      extensions_count="$(docker run --rm \
        -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
        postgres:16-alpine \
        sh -c "psql '$(pg_conn "$db_endpoint" "honua_restore_check")' -tA -c \"SELECT COUNT(*) FROM pg_extension WHERE extname IN ('postgis','postgis_raster');\"" | tr -d '[:space:]')"
    fi

    docker run --rm \
      -e PGPASSWORD="$DB_PASSWORD_EFFECTIVE" \
      postgres:16-alpine \
      sh -c "psql '$(pg_conn "$db_endpoint" "postgres")' -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS honua_restore_check'" >/dev/null
  }

  if [[ "$USE_DOCKER_PG_TOOLS" == "true" ]]; then
    if ! run_restore_drill_docker >"$drill_log" 2>&1; then
      log_error "DB backup/restore drill failed while using dockerized PostgreSQL tools"
      cat "$drill_log" >&2
      rm -f "$dump_file" "$drill_log"
      return 1
    fi
  else
    if ! run_restore_drill_local >"$drill_log" 2>&1; then
      if command -v docker >/dev/null 2>&1; then
        log_warn "Local PostgreSQL tools failed during DB backup/restore drill; retrying with dockerized tools"
        if ! run_restore_drill_docker >"$drill_log" 2>&1; then
          log_error "DB backup/restore drill failed after docker fallback"
          cat "$drill_log" >&2
          rm -f "$dump_file" "$drill_log"
          return 1
        fi
      else
        log_error "DB backup/restore drill failed with local PostgreSQL tools and docker fallback is unavailable"
        cat "$drill_log" >&2
        rm -f "$dump_file" "$drill_log"
        return 1
      fi
    fi
  fi

  rm -f "$dump_file" "$drill_log"

  if [[ ! "$restored_table_count" =~ ^[0-9]+$ ]] || (( restored_table_count == 0 )); then
    log_error "DB backup/restore drill failed: restored DB did not contain expected application tables (count=${restored_table_count:-<none>})"
    return 1
  fi

  if [[ "$extensions_count" != "2" ]]; then
    log_error "DB backup/restore drill failed: expected 2 PostGIS extensions in restored DB, got ${extensions_count:-<none>}"
    return 1
  fi

  log_info "DB backup/restore drill passed"
}

wait_for_ecs_running_count() {
  local cluster_name="$1"
  local service_name="$2"
  local expected_min="$3"
  local timeout="$4"
  local start_epoch
  local current

  start_epoch="$(date +%s)"
  while true; do
    current="$(run_aws ecs describe-services --cluster "$cluster_name" --services "$service_name" --query 'services[0].runningCount' --output text 2>/dev/null || echo 0)"

    if [[ -n "$current" ]] && [[ "$current" != "None" ]] && (( current >= expected_min )); then
      log_info "ECS running count reached target: $current >= $expected_min"
      return 0
    fi

    if (( $(date +%s) - start_epoch > timeout )); then
      log_error "Timed out waiting for ECS running count >= $expected_min (current: ${current:-unknown})"
      return 1
    fi

    sleep 15
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

validate_existing_resource_inputs() {
  local any_existing
  any_existing=false

  if [[ -n "$EXISTING_DB_ENDPOINT" || -n "$EXISTING_DB_CONNECTION_STRING" || -n "$EXISTING_REDIS_CONNECTION_STRING" || -n "$EXISTING_VPC_ID" || -n "$EXISTING_VPC_CIDR" || -n "$EXISTING_PUBLIC_SUBNET_IDS" || -n "$EXISTING_PRIVATE_SUBNET_IDS" ]]; then
    any_existing=true
  fi

  if [[ -n "$EXISTING_DB_ENDPOINT" && -z "$EXISTING_DB_CONNECTION_STRING" ]]; then
    log_error "--existing-db-connection is required when --existing-db-endpoint is provided"
    exit 1
  fi

  if [[ -z "$EXISTING_DB_ENDPOINT" && -n "$EXISTING_DB_CONNECTION_STRING" ]]; then
    log_error "--existing-db-endpoint is required when --existing-db-connection is provided"
    exit 1
  fi

  if [[ "$any_existing" == "true" ]]; then
    if [[ -z "$EXISTING_DB_ENDPOINT" || -z "$EXISTING_DB_CONNECTION_STRING" || -z "$EXISTING_REDIS_CONNECTION_STRING" || -z "$EXISTING_VPC_ID" || -z "$EXISTING_VPC_CIDR" || -z "$EXISTING_PUBLIC_SUBNET_IDS" || -z "$EXISTING_PRIVATE_SUBNET_IDS" ]]; then
      log_error "When reusing AWS data, all values are required: DB endpoint/connection, Redis connection, VPC ID/CIDR, and public/private subnet lists"
      exit 1
    fi
  fi
}

has_existing_data_inputs() {
  [[ -n "$EXISTING_DB_ENDPOINT" &&
    -n "$EXISTING_DB_CONNECTION_STRING" &&
    -n "$EXISTING_REDIS_CONNECTION_STRING" &&
    -n "$EXISTING_VPC_ID" &&
    -n "$EXISTING_VPC_CIDR" &&
    -n "$EXISTING_PUBLIC_SUBNET_IDS" &&
    -n "$EXISTING_PRIVATE_SUBNET_IDS" ]]
}

json_array_items() {
  local raw="$1"
  local csv
  local item

  csv="$(printf '%s' "$raw" | tr -d '[]"[:space:]')"
  [[ -z "$csv" ]] && return 0

  IFS=',' read -r -a _json_array_items <<< "$csv"
  for item in "${_json_array_items[@]}"; do
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}

route_table_id_for_subnet() {
  local subnet_id="$1"
  local route_table_id=""
  local subnet_vpc_id=""
  local attempt

  for attempt in $(seq 1 3); do
    route_table_id="$(run_aws ec2 describe-route-tables \
      --filters "Name=association.subnet-id,Values=$subnet_id" \
      --query 'RouteTables[0].RouteTableId' \
      --output text 2>/dev/null || true)"

    if [[ -n "$route_table_id" && "$route_table_id" != "None" && "$route_table_id" != "null" ]]; then
      printf '%s' "$route_table_id"
      return 0
    fi

    subnet_vpc_id="$(run_aws ec2 describe-subnets \
      --subnet-ids "$subnet_id" \
      --query 'Subnets[0].VpcId' \
      --output text 2>/dev/null || true)"

    if [[ -n "$subnet_vpc_id" && "$subnet_vpc_id" != "None" && "$subnet_vpc_id" != "null" ]]; then
      route_table_id="$(run_aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$subnet_vpc_id" "Name=association.main,Values=true" \
        --query 'RouteTables[0].RouteTableId' \
        --output text 2>/dev/null || true)"

      if [[ -n "$route_table_id" && "$route_table_id" != "None" && "$route_table_id" != "null" ]]; then
        printf '%s' "$route_table_id"
        return 0
      fi
    fi

    sleep 2
  done

  return 1
}

route_table_default_route_target() {
  local route_table_id="$1"
  run_aws ec2 describe-route-tables \
    --route-table-ids "$route_table_id" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`][0].[NatGatewayId,GatewayId,TransitGatewayId,InstanceId,NetworkInterfaceId]' \
    --output text 2>/dev/null || true
}

subnet_has_igw_default_route() {
  local subnet_id="$1"
  local gateway_id
  local route_table_id

  route_table_id="$(route_table_id_for_subnet "$subnet_id")"
  if [[ -z "$route_table_id" || "$route_table_id" == "None" || "$route_table_id" == "null" ]]; then
    return 1
  fi

  gateway_id="$(run_aws ec2 describe-route-tables \
    --route-table-ids "$route_table_id" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
    --output text 2>/dev/null || true)"

  [[ "$gateway_id" == igw-* ]]
}

select_reuse_public_nat_subnet() {
  local subnet_id

  while IFS= read -r subnet_id; do
    [[ -z "$subnet_id" ]] && continue
    if subnet_has_igw_default_route "$subnet_id"; then
      printf '%s' "$subnet_id"
      return 0
    fi
  done < <(json_array_items "$EXISTING_PUBLIC_SUBNET_IDS")

  return 1
}

find_existing_reuse_nat_gateway() {
  run_aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=$EXISTING_VPC_ID" "Name=state,Values=available,pending" \
    --query 'NatGateways[0].NatGatewayId' \
    --output text 2>/dev/null || true
}

wait_for_nat_gateway_available() {
  local nat_gateway_id="$1"
  local nat_state=""
  local attempt

  for attempt in $(seq 1 60); do
    nat_state="$(run_aws ec2 describe-nat-gateways \
      --nat-gateway-ids "$nat_gateway_id" \
      --query 'NatGateways[0].State' \
      --output text 2>/dev/null || true)"

    case "$nat_state" in
      available)
        return 0
        ;;
      failed|deleted|deleting)
        log_error "NAT gateway $nat_gateway_id entered terminal state '$nat_state'"
        return 1
        ;;
    esac

    sleep 10
  done

  log_error "Timed out waiting for NAT gateway $nat_gateway_id to become available"
  return 1
}

create_reuse_nat_gateway() {
  local public_subnet_id="$1"
  local eip_allocation_id=""
  local nat_gateway_id=""

  eip_allocation_id="$(run_aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)"
  run_aws ec2 create-tags \
    --resources "$eip_allocation_id" \
    --tags \
      "Key=Name,Value=${NAME_PREFIX_BASE}-${ENVIRONMENT}-reuse-nat-eip" \
      "Key=Owner,Value=terraform-validation" \
      "Key=ValidationRunId,Value=$VALIDATION_RUN_ID" >/dev/null

  nat_gateway_id="$(run_aws ec2 create-nat-gateway \
    --subnet-id "$public_subnet_id" \
    --allocation-id "$eip_allocation_id" \
    --query 'NatGateway.NatGatewayId' \
    --output text)"

  run_aws ec2 create-tags \
    --resources "$nat_gateway_id" \
    --tags \
      "Key=Name,Value=${NAME_PREFIX_BASE}-${ENVIRONMENT}-reuse-nat" \
      "Key=Owner,Value=terraform-validation" \
      "Key=ValidationRunId,Value=$VALIDATION_RUN_ID" >/dev/null

  wait_for_nat_gateway_available "$nat_gateway_id"
  printf '%s' "$nat_gateway_id"
}

ensure_existing_vpc_private_egress() {
  local public_nat_subnet=""
  local nat_gateway_id=""
  local private_subnet_id=""
  local route_table_id=""
  local default_route_target=""
  local updated_route_tables=0
  declare -A route_tables_needing_nat=()

  validate_boolean_value "HONUA_AWS_AUTO_REPAIR_VPC_EGRESS" "$AUTO_REPAIR_VPC_EGRESS"

  if [[ "$AUTO_REPAIR_VPC_EGRESS" != "true" ]]; then
    return 0
  fi

  if ! has_existing_data_inputs; then
    return 0
  fi

  while IFS= read -r private_subnet_id; do
    [[ -z "$private_subnet_id" ]] && continue

    route_table_id="$(route_table_id_for_subnet "$private_subnet_id")"
    if [[ -z "$route_table_id" || "$route_table_id" == "None" ]]; then
      log_error "Could not resolve route table for reused private subnet $private_subnet_id"
      return 1
    fi

    default_route_target="$(route_table_default_route_target "$route_table_id")"
    if [[ -z "$default_route_target" || "$default_route_target" == "None" ]]; then
      route_tables_needing_nat["$route_table_id"]=1
    fi
  done < <(json_array_items "$EXISTING_PRIVATE_SUBNET_IDS")

  if (( ${#route_tables_needing_nat[@]} == 0 )); then
    return 0
  fi

  log_warn "Reused AWS private subnets in $EXISTING_VPC_ID lack outbound egress; repairing VPC for runtime access"

  nat_gateway_id="$(find_existing_reuse_nat_gateway)"
  if [[ -z "$nat_gateway_id" || "$nat_gateway_id" == "None" ]]; then
    if ! public_nat_subnet="$(select_reuse_public_nat_subnet)"; then
      log_error "Could not find a reused public subnet with an internet gateway route in $EXISTING_VPC_ID"
      return 1
    fi

    nat_gateway_id="$(create_reuse_nat_gateway "$public_nat_subnet")"
    log_info "Provisioned reuse NAT gateway $nat_gateway_id in public subnet $public_nat_subnet"
  else
    wait_for_nat_gateway_available "$nat_gateway_id"
    log_info "Reusing existing NAT gateway $nat_gateway_id for $EXISTING_VPC_ID"
  fi

  for route_table_id in "${!route_tables_needing_nat[@]}"; do
    if ! run_aws ec2 create-route \
      --route-table-id "$route_table_id" \
      --destination-cidr-block 0.0.0.0/0 \
      --nat-gateway-id "$nat_gateway_id" >/dev/null 2>&1; then
      run_aws ec2 replace-route \
        --route-table-id "$route_table_id" \
        --destination-cidr-block 0.0.0.0/0 \
        --nat-gateway-id "$nat_gateway_id" >/dev/null
    fi
    updated_route_tables=$((updated_route_tables + 1))
  done

  log_info "Ensured outbound egress for $updated_route_tables reused private route table(s) via NAT gateway $nat_gateway_id"
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
  if [[ -n "$EXISTING_DB_CONNECTION_STRING" && -n "$EXISTING_VPC_CIDR" ]]; then
    export TF_VAR_existing_db_cidrs="[\"$EXISTING_VPC_CIDR\"]"
  else
    export TF_VAR_existing_db_cidrs="[]"
  fi
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

apply_data_stack() {
  local db_connection_secret_arn
  local redis_connection_secret_arn

  log_info "Applying AWS data stack (RDS + Redis)"
  set_data_tf_vars

  run_tf -chdir=examples/aws-data init -input=false -no-color
  plan_apply "examples/aws-data" "data.tfplan" "data"

  EXISTING_DB_ENDPOINT="$(terraform_stack_database_host "examples/aws-data")"
  db_connection_secret_arn="$(terraform_stack_database_secret_ref "examples/aws-data")"
  redis_connection_secret_arn="$(terraform_stack_cache_secret_ref "examples/aws-data")"
  EXISTING_DB_CONNECTION_STRING="$(aws_secret_string "$db_connection_secret_arn")"
  EXISTING_REDIS_CONNECTION_STRING="$(aws_secret_string "$redis_connection_secret_arn")"
  EXISTING_VPC_ID="$(terraform_stack_network_id "examples/aws-data")"
  EXISTING_VPC_CIDR="$(terraform_stack_network_cidr "examples/aws-data")"
  EXISTING_PUBLIC_SUBNET_IDS="$(terraform_stack_public_subnet_ids_json "examples/aws-data")"
  EXISTING_PRIVATE_SUBNET_IDS="$(terraform_stack_private_subnet_ids_json "examples/aws-data")"

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

run_ecs_checks() {
  local url="$1"
  local db_endpoint="$2"

  wait_for_ready "$url" "$TIMEOUT_SECONDS"
  if [[ "$CHECK_PROTOCOLS" == "true" ]]; then
    verify_protocol_endpoints "$url"
    run_admin_api_crud_smoke "$url" "$db_endpoint"
  fi
  verify_postgis_extensions "$db_endpoint"
  if [[ "$RUN_DB_RESILIENCE" == "true" ]]; then
    verify_db_backup_restore "$db_endpoint"
  fi
  run_load_probe "$url" "$LOAD_REQUESTS" "$LOAD_CONCURRENCY"
}

verify_ecs_canary_route() {
  local url="$1"
  local cluster_name="$2"
  local normalized
  local canary_enabled
  local canary_service_name
  local canary_header_name
  local canary_header_value

  canary_enabled="$(terraform_stack_canary_enabled "examples/aws")"
  if [[ "$canary_enabled" != "true" ]]; then
    return 0
  fi

  canary_service_name="$(terraform_stack_canary_service_name "examples/aws")"
  canary_header_name="$(terraform_stack_canary_header_name "examples/aws")"
  canary_header_value="$(terraform_stack_canary_header_value "examples/aws")"

  if [[ -z "$canary_service_name" || "$canary_service_name" == "null" ]]; then
    log_error "Canary validation failed: canary service name output was empty"
    return 1
  fi

  if [[ -z "$canary_header_name" || "$canary_header_name" == "null" || -z "$canary_header_value" || "$canary_header_value" == "null" ]]; then
    log_error "Canary validation failed: canary verification header output was empty"
    return 1
  fi

  wait_for_ecs_running_count "$cluster_name" "$canary_service_name" "$ECS_CANARY_DESIRED_COUNT" 900

  normalized="$(normalize_base_url "$url")"
  curl -fsSL --max-time 20 \
    -H "${canary_header_name}: ${canary_header_value}" \
    "${normalized}/healthz/ready" >/dev/null

  log_info "Verified ECS ALB canary route via header '${canary_header_name}: ${canary_header_value}'"
}

run_serverless_checks() {
  local url="$1"
  local db_endpoint="$2"
  local serverless_load_requests="$LOAD_REQUESTS"
  local serverless_load_concurrency="$LOAD_CONCURRENCY"

  # Lambda + API Gateway validation runs target small ephemeral footprints.
  # Keep strict error-rate expectations while using a lighter default burst profile.
  if [[ "$LOAD_REQUESTS" == "120" && "$LOAD_CONCURRENCY" == "20" ]]; then
    serverless_load_requests=40
    serverless_load_concurrency=5
    log_info "Using serverless load probe defaults: ${serverless_load_requests} requests, concurrency ${serverless_load_concurrency}"
  fi

  wait_for_ready "$url" "$TIMEOUT_SECONDS"
  if [[ "$CHECK_PROTOCOLS" == "true" ]]; then
    verify_protocol_endpoints "$url"
    run_admin_api_crud_smoke "$url" "$db_endpoint"
  fi
  verify_postgis_extensions "$db_endpoint"
  if [[ "$RUN_DB_RESILIENCE" == "true" ]]; then
    verify_db_backup_restore "$db_endpoint"
  fi
  run_load_probe "$url" "$serverless_load_requests" "$serverless_load_concurrency"
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

    url="$(terraform_stack_base_url "examples/aws")"
    db_endpoint="$(terraform_stack_database_host "examples/aws")"
    cluster_name="$(terraform_stack_cluster_name "examples/aws")"
    service_name="$(terraform_stack_workload_name "examples/aws")"

    if [[ -n "$EXISTING_REDIS_CONNECTION_STRING" ]]; then
      log_info "Using existing Redis connection string; skipping ECS Redis endpoint creation check"
    else
      redis_endpoint="$(terraform_stack_cache_host "examples/aws")"
      if [[ -z "$redis_endpoint" || "$redis_endpoint" == "null" ]]; then
        log_error "Redis endpoint was empty for ECS stack"
        return 1
      fi
    fi

    run_ecs_checks "$url" "$db_endpoint"
    verify_ecs_canary_route "$url" "$cluster_name"

    export TF_VAR_honua_image="$ECS_IMAGE"
    plan_apply "examples/aws" "ecs-upgrade.tfplan" "ecs-upgrade"
    url="$(terraform_stack_base_url "examples/aws")"
    db_endpoint="$(terraform_stack_database_host "examples/aws")"
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

    url="$(terraform_stack_base_url "examples/aws")"
    db_endpoint="$(terraform_stack_database_host "examples/aws")"
    cluster_name="$(terraform_stack_cluster_name "examples/aws")"
    service_name="$(terraform_stack_workload_name "examples/aws")"

    if [[ -n "$EXISTING_REDIS_CONNECTION_STRING" ]]; then
      log_info "Using existing Redis connection string; skipping ECS Redis endpoint creation check"
    else
      redis_endpoint="$(terraform_stack_cache_host "examples/aws")"
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

  tf_output_json="$(load_terraform_output_json "examples/aws")"

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
  log_info "ECS URL: $(terraform_stack_base_url "examples/aws")"
}

apply_serverless_stack() {
  local url
  local db_endpoint
  local redis_connection
  local redis_connection_secret_arn
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

    url="$(terraform_stack_base_url "examples/aws-serverless")"
    db_endpoint="$(terraform_stack_database_host "examples/aws-serverless")"
    redis_connection_secret_arn="$(terraform_stack_cache_secret_ref "examples/aws-serverless")"
    redis_connection="$(aws_secret_string "$redis_connection_secret_arn")"

    if [[ -z "$redis_connection" || "$redis_connection" == "null" ]]; then
      log_error "Redis connection string was empty for serverless stack"
      return 1
    fi

    run_serverless_checks "$url" "$db_endpoint"
    previous_live_revision="$(terraform_stack_current_revision "examples/aws-serverless")"
    if [[ -z "$previous_live_revision" || "$previous_live_revision" == "null" ]]; then
      log_error "Serverless validation requires a stable Lambda alias revision before publishing the new version"
      return 1
    fi

    export TF_VAR_honua_image_uri="$SERVERLESS_IMAGE"
    export TF_VAR_lambda_alias_version="$previous_live_revision"
    plan_apply "examples/aws-serverless" "serverless-stage-current.tfplan" "serverless-stage-current"
    url="$(terraform_stack_base_url "examples/aws-serverless")"
    db_endpoint="$(terraform_stack_database_host "examples/aws-serverless")"
    desired_revision="$(terraform_stack_desired_revision "examples/aws-serverless")"
    if [[ -z "$desired_revision" || "$desired_revision" == "null" || "$desired_revision" == "$previous_live_revision" ]]; then
      log_error "Serverless validation requires a newly published Lambda version that differs from the stable alias revision"
      return 1
    fi
    run_serverless_checks "$url" "$db_endpoint"
  else
    plan_apply "examples/aws-serverless" "serverless.tfplan" "serverless"

    url="$(terraform_stack_base_url "examples/aws-serverless")"
    db_endpoint="$(terraform_stack_database_host "examples/aws-serverless")"
    redis_connection_secret_arn="$(terraform_stack_cache_secret_ref "examples/aws-serverless")"
    redis_connection="$(aws_secret_string "$redis_connection_secret_arn")"

    if [[ -z "$redis_connection" || "$redis_connection" == "null" ]]; then
      log_error "Redis connection string was empty for serverless stack"
      return 1
    fi

    run_serverless_checks "$url" "$db_endpoint"
  fi

  if [[ "$CHECK_IDEMPOTENCY" == "true" ]]; then
    assert_idempotent_plan "examples/aws-serverless"
  fi

  tf_output_json="$(load_terraform_output_json "examples/aws-serverless")"

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
    url="$(terraform_stack_base_url "examples/aws-serverless")"
    db_endpoint="$(terraform_stack_database_host "examples/aws-serverless")"
    run_serverless_checks "$url" "$db_endpoint"
  fi

  log_info "Serverless stack checks passed"
  log_info "Serverless URL: $(terraform_stack_base_url "examples/aws-serverless")"
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

main() {
  parse_args "$@"
  apply_aot_mode
  validate_requested_images
  validate_ecs_canary_inputs
  require_command curl
  require_env \
    AWS_ACCESS_KEY_ID \
    AWS_SECRET_ACCESS_KEY \
    HONUA_ADMIN_PASSWORD \
    HONUA_DB_PASSWORD

  export AWS_REGION="$REGION"
  export AWS_DEFAULT_REGION="$REGION"

  validate_admin_password
  resolve_data_retention_mode
  load_data_reuse_cache
  validate_existing_resource_inputs
  ensure_existing_db_connection_string_shape
  resolve_db_password_for_checks
  if [[ -n "$EXISTING_DB_CONNECTION_STRING" && "$RUN_DB_RESILIENCE" == "true" ]]; then
    log_info "Skipping DB backup/restore drill when reusing an existing DB connection"
    RUN_DB_RESILIENCE=false
  fi
  normalize_identifiers
  detect_db_ingress_cidr
  detect_http_ingress_cidr
  configure_runtime_tools
  assert_cost_guardrail
  run_quota_preflight
  prepare_tf_workspace

  trap cleanup EXIT
  authorize_existing_db_runner_ingress

  log_info "Starting AWS Terraform integration test"
  log_info "Validation run ID: $VALIDATION_RUN_ID"
  log_info "Stack selection: $STACK"
  log_info "AOT mode: $USE_AOT"
  log_info "ECS image: $ECS_IMAGE"
  if [[ -n "$SERVERLESS_IMAGE" ]]; then
    log_info "Serverless image: $SERVERLESS_IMAGE"
  fi
  log_info "Region: $REGION"
  log_info "Environment: $ENVIRONMENT"
  log_info "Data prefix: $DATA_NAME_PREFIX"
  log_info "ECS prefix: $ECS_NAME_PREFIX"
  log_info "Serverless prefix: $SERVERLESS_NAME_PREFIX"
  log_info "DB ingress CIDR: $DB_INGRESS_CIDR"
  log_info "Ready SLO seconds: $READY_SLO_SECONDS"
  log_info "Max load error rate: ${MAX_LOAD_ERROR_RATE_PERCENT}%"
  log_info "Destroy data on cleanup: $DESTROY_DATA"
  log_info "Data cache file: $DATA_CACHE_FILE"

  if [[ "$STACK" == "data" ]]; then
    if has_existing_data_inputs && [[ "$FORCE_NEW_DATA_INFRA" != "true" ]]; then
      log_info "Existing data inputs already available; skipping new data provisioning (--force-new-data-infra to recreate)"
      log_info "Existing DB endpoint: $EXISTING_DB_ENDPOINT"
      return
    fi
    apply_data_stack
    log_info "AWS data stack provisioning completed successfully"
    return
  fi

  if has_existing_data_inputs; then
    log_info "Using caller-provided DB/Redis/VPC data stack inputs"
    DATA_CREATED=false
  else
    apply_data_stack
  fi

  if [[ "$STACK" == "ecs" || "$STACK" == "both" ]]; then
    apply_ecs_stack
  fi

  if [[ "$STACK" == "serverless" || "$STACK" == "both" ]]; then
    apply_serverless_stack
  fi

  log_info "AWS Terraform integration checks completed successfully"
}

main "$@"
