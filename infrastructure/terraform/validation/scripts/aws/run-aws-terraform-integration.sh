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


source "$SCRIPT_DIR/lib/validation.sh"

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
