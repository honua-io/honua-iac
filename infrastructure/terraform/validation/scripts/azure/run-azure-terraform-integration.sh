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
LOCATION="${AZURE_LOCATION:-westus}"
ENVIRONMENT="${AZURE_TF_ENVIRONMENT:-it}"
NAME_PREFIX_BASE="${AZURE_TF_NAME_PREFIX_BASE:-h$(date -u +%m%d%H%M)$((RANDOM % 10))}"
DEFAULT_HONUA_IMAGE="ghcr.io/honua-io/honua-server:latest"
DEFAULT_HONUA_AOT_IMAGE="ghcr.io/honua-io/honua-server:latest-aot"
DEFAULT_HONUA_FUNCTIONS_AOT_IMAGE="${HONUA_DEFAULT_FUNCTIONS_AOT_IMAGE:-ghcr.io/honua-io/honua-server:latest-aot}"
DEFAULT_HONUA_FUNCTIONS_IMAGE="${HONUA_DEFAULT_FUNCTIONS_IMAGE:-$DEFAULT_HONUA_FUNCTIONS_AOT_IMAGE}"
USE_AOT="${HONUA_USE_AOT:-false}"
FUNCTIONS_AOT_AUTOSWITCH="${HONUA_AZURE_FUNCTIONS_AOT_AUTOSWITCH:-true}"
ACA_IMAGE="${HONUA_ACA_IMAGE:-}"
FUNCTIONS_IMAGE="${HONUA_FUNCTIONS_IMAGE:-}"
ACA_PREVIOUS_IMAGE="${HONUA_ACA_PREVIOUS_IMAGE:-}"
FUNCTIONS_PREVIOUS_IMAGE="${HONUA_FUNCTIONS_PREVIOUS_IMAGE:-}"
FUNCTIONS_DEPLOYMENT_SLOT_ENABLED="${HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_ENABLED:-false}"
FUNCTIONS_DEPLOYMENT_SLOT_NAME="${HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_NAME:-staging}"
FUNCTIONS_DEPLOYMENT_SLOT_IMAGE="${HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_IMAGE:-}"
FUNCTIONS_PLAN_SKU="${HONUA_FUNCTIONS_PLAN_SKU:-EP1}"
FUNCTIONS_SKIP_MIGRATIONS="${HONUA_AZURE_FUNCTIONS_SKIP_MIGRATIONS:-false}"
AUTO_DESTROY=true
DESTROY_DATA="${HONUA_AZURE_DESTROY_DATA:-}"
DESTROY_DATA_MODE_EXPLICIT=false
KEEP_DATA="${HONUA_AZURE_KEEP_DATA:-false}"
QUICK_SCALE=true
CHECK_IDEMPOTENCY=true
CHECK_PROTOCOLS=true
RUN_DB_RESILIENCE=true
RUN_UPGRADE_ROLLBACK=false
RUN_QUOTA_PREFLIGHT=true
TIMEOUT_SECONDS="${HONUA_AZURE_TEST_TIMEOUT_SECONDS:-900}"
LOAD_REQUESTS="${HONUA_AZURE_LOAD_REQUESTS:-120}"
LOAD_CONCURRENCY="${HONUA_AZURE_LOAD_CONCURRENCY:-20}"
ACA_MIN_REPLICAS="${HONUA_AZURE_ACA_MIN_REPLICAS:-1}"
ACA_MAX_REPLICAS="${HONUA_AZURE_ACA_MAX_REPLICAS:-3}"
ACA_SCALE_TARGET_MIN_REPLICAS="${HONUA_AZURE_ACA_SCALE_TARGET_MIN_REPLICAS:-2}"
READY_SLO_SECONDS="${HONUA_READY_SLO_SECONDS:-600}"
MAX_LOAD_ERROR_RATE_PERCENT="${HONUA_MAX_LOAD_ERROR_RATE_PERCENT:-0}"
MAX_RUN_COST_USD="${HONUA_MAX_RUN_COST_USD:-0}"
TF_IMAGE="${HONUA_TERRAFORM_IMAGE:-honua-terraform-psql:1.8.5}"
AZ_CLI_IMAGE="${HONUA_AZ_CLI_IMAGE:-mcr.microsoft.com/azure-cli:2.65.0}"
PLAN_ARTIFACT_DIR="${HONUA_TF_PLAN_ARTIFACT_DIR:-}"
ALLOW_DESTROY_PLAN="${HONUA_ALLOW_DESTROY_PLAN:-false}"
TTL_HOURS="${HONUA_TTL_HOURS:-8}"
VALIDATION_RUN_ID="${HONUA_VALIDATION_RUN_ID:-az-$(date -u +%Y%m%d%H%M%S)}"
DB_FIREWALL_START_IP="${HONUA_AZURE_DB_FIREWALL_START_IP:-}"
DB_FIREWALL_END_IP="${HONUA_AZURE_DB_FIREWALL_END_IP:-}"
EXISTING_DB_FQDN="${HONUA_AZURE_EXISTING_DB_FQDN:-}"
EXISTING_DB_RESOURCE_GROUP="${HONUA_AZURE_EXISTING_DB_RESOURCE_GROUP:-}"
EXISTING_DB_CONNECTION_STRING="${HONUA_AZURE_EXISTING_DB_CONNECTION_STRING:-}"
EXISTING_REDIS_CONNECTION_STRING="${HONUA_AZURE_EXISTING_REDIS_CONNECTION_STRING:-}"
REGISTRY_SERVER="${HONUA_AZURE_REGISTRY_SERVER:-}"
REGISTRY_USERNAME="${HONUA_AZURE_REGISTRY_USERNAME:-}"
REGISTRY_PASSWORD="${HONUA_AZURE_REGISTRY_PASSWORD:-}"
AUTO_PROVISION_DATA_STACK=true
DATA_DB_SKU_NAME="${HONUA_AZURE_DATA_DB_SKU_NAME:-B_Standard_B1ms}"
DATA_DB_STORAGE_MB="${HONUA_AZURE_DATA_DB_STORAGE_MB:-32768}"
DATA_DB_GEO_REDUNDANT_BACKUP_ENABLED="${HONUA_AZURE_DATA_DB_GEO_REDUNDANT_BACKUP_ENABLED:-false}"
DATA_DB_BACKUP_RETENTION_DAYS="${HONUA_AZURE_DATA_DB_BACKUP_RETENTION_DAYS:-7}"
DATA_DB_PUBLIC_NETWORK_ACCESS="${HONUA_AZURE_DATA_DB_PUBLIC_NETWORK_ACCESS:-true}"
DATA_REDIS_SKU_NAME="${HONUA_AZURE_DATA_REDIS_SKU_NAME:-Basic}"
DATA_REDIS_FAMILY="${HONUA_AZURE_DATA_REDIS_FAMILY:-C}"
DATA_REDIS_CAPACITY="${HONUA_AZURE_DATA_REDIS_CAPACITY:-0}"
DATA_REDIS_PUBLIC_NETWORK_ACCESS_ENABLED="${HONUA_AZURE_DATA_REDIS_PUBLIC_NETWORK_ACCESS_ENABLED:-true}"
DATA_CACHE_FILE="${HONUA_AZURE_DATA_CACHE_FILE:-/tmp/honua-azure-data-reuse.env}"
DATA_CACHE_FORMAT="v2-base64"
FORCE_NEW_DATA_INFRA="${HONUA_AZURE_FORCE_NEW_DATA_INFRA:-${HONUA_AZURE_FORCE_NEW_DATA:-false}}"

TEMP_TF_ROOT=""
DATA_APPLIED=false
DATA_CREATED=false
ACA_APPLIED=false
FUNCTIONS_APPLIED=false

DATA_NAME_PREFIX=""
ACA_NAME_PREFIX=""
FUNCTIONS_NAME_PREFIX=""
DATA_RESOURCE_GROUP=""
EXPIRES_AT_UTC=""
DB_PASSWORD_EFFECTIVE=""
ACA_DB_FIREWALL_RULES=()
FUNCTIONS_DB_FIREWALL_RULES=()
EXISTING_DB_FIREWALL_RULES=()
USE_DOCKER_TF=false
USE_DOCKER_AZ_CLI=false
USE_DOCKER_PG_TOOLS=false
AZ_SESSION_INITIALIZED=false
AZ_SESSION_CLIENT_ID=""
AZ_SESSION_TENANT_ID=""
AZ_SESSION_SUBSCRIPTION_ID=""
AZ_CONFIG_DIR_DEFAULT="${HONUA_AZURE_CONFIG_DIR:-/tmp/azcfg-honua}"
AZ_LOGIN_MAX_ATTEMPTS="${HONUA_AZURE_LOGIN_MAX_ATTEMPTS:-18}"
AZ_LOGIN_RETRY_SECONDS="${HONUA_AZURE_LOGIN_RETRY_SECONDS:-10}"

usage() {
  cat <<USAGE
Run live Terraform integration tests for Azure ACA and Azure Functions.

Usage:
  ./infrastructure/terraform/validation/scripts/azure/run-azure-terraform-integration.sh [options]

When existing DB/Redis settings are not provided, the script provisions 'examples/azure-data'
first and then feeds those outputs into ACA/Functions validation applies.

Options:
  --stack <aca|functions|both>        Stack to test (default: both)
  --location <azure-region>           Azure region (default: westus)
  --environment <name>                Environment suffix in names (default: it)
  --name-prefix-base <prefix>         Base prefix for generated resource names
  --aot                               Use latest-aot for ACA and Functions (override HONUA_DEFAULT_FUNCTIONS_AOT_IMAGE if needed; JIT is debug fallback)
  --aca-image <image>                 ACA image tag
  --functions-image <image>           Functions image tag
  --aca-previous-image <image>        Previous ACA image for upgrade/rollback validation
  --functions-previous-image <image>  Previous Functions image for upgrade/rollback validation
  --upgrade-rollback                  Enable upgrade/rollback validation sequence
  --functions-plan <EP1|EP2|EP3|Y1>   Functions plan SKU (default: EP1)
  --timeout-seconds <n>               Health wait timeout per stack (default: 900)
  --max-ready-seconds <n>             Ready SLO threshold (default: 600)
  --max-load-error-rate <percent>     Max allowed load error rate (default: 0)
  --max-run-cost-usd <n>              Max allowed estimated run cost (0 disables cap)
  --data-db-sku <name>                Azure data stack PostgreSQL SKU (default: B_Standard_B1ms)
  --data-db-storage-mb <n>            Azure data stack PostgreSQL storage in MB (default: 32768)
  --data-db-geo-backup <true|false>   Azure data stack PostgreSQL geo backup (default: false)
  --data-db-backup-retention-days <n> Azure data stack PostgreSQL backup retention (default: 7)
  --data-redis-sku <Basic|Standard>   Azure data stack Redis SKU (default: Basic)
  --data-redis-family <char>          Azure data stack Redis family (default: C)
  --data-redis-capacity <n>           Azure data stack Redis capacity (default: 0)
  --existing-db-fqdn <fqdn>           Reuse existing PostgreSQL server FQDN
  --existing-db-connection <string>   Reuse existing PostgreSQL connection string
  --existing-redis-connection <str>   Reuse existing Redis connection string
  --plan-artifact-dir <path>          Directory to persist plan artifacts
  --allow-destroy-plan                Allow plans containing resource destroys
  --ttl-hours <n>                     TTL tag value for provisioned resources (default: 8)
  --skip-quota-preflight              Skip Azure quota preflight checks
  --skip-idempotency                  Skip post-apply zero-drift plan assertion
  --skip-protocol-checks              Skip REST/OGC/OData/admin auth + admin CRUD/query smoke checks
  --skip-db-resilience                Skip DB backup/restore drill
  --no-scale-check                    Skip quick ACA scale check
  --destroy-data                      Destroy auto-created Azure data stack during cleanup (default)
  --keep-data                         Keep auto-created Azure data stack for reuse and enable local cache reuse
  --force-new-data-infra              Ignore cached/existing data inputs and create a fresh data stack
  --force-new-data                    Deprecated alias for --force-new-data-infra
  --no-destroy                        Keep resources after test run
  --help, -h                          Show this help

Required environment variables:
  ARM_CLIENT_ID
  ARM_CLIENT_SECRET
  ARM_TENANT_ID
  ARM_SUBSCRIPTION_ID
  HONUA_ADMIN_PASSWORD (at least 32 chars)
  HONUA_DB_PASSWORD
  HONUA_ACA_IMAGE (when --stack aca|both)
  HONUA_FUNCTIONS_IMAGE (when --stack functions|both)

Optional environment variables:
  HONUA_AZURE_DESTROY_DATA
  HONUA_AZURE_KEEP_DATA
  HONUA_AZURE_DATA_CACHE_FILE
  HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_ENABLED
  HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_NAME
  HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_IMAGE
  HONUA_AZURE_FUNCTIONS_SKIP_MIGRATIONS
  HONUA_AZURE_FORCE_NEW_DATA_INFRA
  HONUA_AZURE_LOGIN_MAX_ATTEMPTS
  HONUA_AZURE_LOGIN_RETRY_SECONDS
  HONUA_PLATFORM_VALIDATION_SCRIPT
USAGE
}

log_info() {
  echo "[INFO] $1"
}

log_warn() {
  echo "[WARN] $1" >&2
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

source "$SCRIPT_DIR/lib/runtime.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/verification.sh"
source "$SCRIPT_DIR/lib/network.sh"
source "$SCRIPT_DIR/lib/stacks.sh"
source "$SCRIPT_DIR/lib/lifecycle.sh"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack)
        STACK="$2"
        shift 2
        ;;
      --location)
        LOCATION="$2"
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
      --aca-image)
        ACA_IMAGE="$2"
        shift 2
        ;;
      --functions-image)
        FUNCTIONS_IMAGE="$2"
        shift 2
        ;;
      --aca-previous-image)
        ACA_PREVIOUS_IMAGE="$2"
        shift 2
        ;;
      --functions-previous-image)
        FUNCTIONS_PREVIOUS_IMAGE="$2"
        shift 2
        ;;
      --upgrade-rollback)
        RUN_UPGRADE_ROLLBACK=true
        shift
        ;;
      --functions-plan)
        FUNCTIONS_PLAN_SKU="$2"
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
      --data-db-sku)
        DATA_DB_SKU_NAME="$2"
        shift 2
        ;;
      --data-db-storage-mb)
        DATA_DB_STORAGE_MB="$2"
        shift 2
        ;;
      --data-db-geo-backup)
        DATA_DB_GEO_REDUNDANT_BACKUP_ENABLED="$2"
        shift 2
        ;;
      --data-db-backup-retention-days)
        DATA_DB_BACKUP_RETENTION_DAYS="$2"
        shift 2
        ;;
      --data-redis-sku)
        DATA_REDIS_SKU_NAME="$2"
        shift 2
        ;;
      --data-redis-family)
        DATA_REDIS_FAMILY="$2"
        shift 2
        ;;
      --data-redis-capacity)
        DATA_REDIS_CAPACITY="$2"
        shift 2
        ;;
      --existing-db-fqdn)
        EXISTING_DB_FQDN="$2"
        shift 2
        ;;
      --existing-db-resource-group)
        EXISTING_DB_RESOURCE_GROUP="$2"
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

  if [[ "$STACK" != "aca" && "$STACK" != "functions" && "$STACK" != "both" ]]; then
    log_error "Invalid --stack value: $STACK"
    exit 1
  fi
}

main() {
  parse_args "$@"
  apply_aot_mode
  validate_requested_images
  require_command curl
  require_env \
    ARM_CLIENT_ID \
    ARM_CLIENT_SECRET \
    ARM_TENANT_ID \
    ARM_SUBSCRIPTION_ID \
    HONUA_ADMIN_PASSWORD \
    HONUA_DB_PASSWORD

  validate_admin_password
  validate_boolean_flags
  load_data_reuse_cache
  normalize_identifiers
  validate_existing_resource_inputs
  configure_data_stack_mode
  validate_existing_data_stack_availability
  ensure_existing_db_connection_string_shape
  ensure_existing_redis_connection_string_shape
  resolve_db_password_for_checks
  configure_runtime_tools
  assert_cost_guardrail
  run_quota_preflight
  detect_db_firewall_ips
  prepare_tf_workspace

  trap cleanup EXIT
  ensure_existing_db_firewall_access

  log_info "Starting Azure Terraform integration test"
  log_info "Validation run ID: $VALIDATION_RUN_ID"
  log_info "Stack selection: $STACK"
  log_info "AOT mode: $USE_AOT"
  log_info "Functions AOT autoswitch: $FUNCTIONS_AOT_AUTOSWITCH"
  log_info "Functions skip migrations: $FUNCTIONS_SKIP_MIGRATIONS"
  log_info "ACA image: $ACA_IMAGE"
  log_info "Functions image: $FUNCTIONS_IMAGE"
  log_info "Region: $LOCATION"
  log_info "Environment: $ENVIRONMENT"
  log_info "Data prefix: $DATA_NAME_PREFIX"
  log_info "Data DB SKU/storage: $DATA_DB_SKU_NAME / ${DATA_DB_STORAGE_MB}MB"
  log_info "Data DB geo-backup/retention-days: $DATA_DB_GEO_REDUNDANT_BACKUP_ENABLED / $DATA_DB_BACKUP_RETENTION_DAYS"
  log_info "Data Redis SKU/family/capacity: $DATA_REDIS_SKU_NAME/$DATA_REDIS_FAMILY/$DATA_REDIS_CAPACITY"
  log_info "ACA prefix: $ACA_NAME_PREFIX"
  log_info "Functions prefix: $FUNCTIONS_NAME_PREFIX"
  log_info "DB firewall range: $DB_FIREWALL_START_IP - $DB_FIREWALL_END_IP"
  log_info "Destroy data on cleanup: $DESTROY_DATA"
  log_info "Data cache file: $DATA_CACHE_FILE"
  if [[ -n "$EXISTING_DB_FQDN" ]]; then
    log_info "Reusing existing DB FQDN: $EXISTING_DB_FQDN"
  fi
  if [[ -n "$EXISTING_DB_RESOURCE_GROUP" ]]; then
    log_info "Reusing existing DB resource group: $EXISTING_DB_RESOURCE_GROUP"
  fi
  if [[ -n "$EXISTING_REDIS_CONNECTION_STRING" ]]; then
    log_info "Reusing existing Redis connection string"
  fi
  log_info "Ready SLO seconds: $READY_SLO_SECONDS"
  log_info "Max load error rate: ${MAX_LOAD_ERROR_RATE_PERCENT}%"

  apply_data_stack

  if [[ "$STACK" == "aca" || "$STACK" == "both" ]]; then
    apply_aca_stack
  fi

  if [[ "$STACK" == "functions" || "$STACK" == "both" ]]; then
    apply_functions_stack
  fi

  log_info "Azure Terraform integration checks completed successfully"
}

main "$@"
