#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO="honua-io/honua-terraform"
WORKFLOW="terraform-manual-validation.yml"
REF=""
CLOUD="both"
DEPLOYMENT_PROFILE="ephemeral"
APPLY_CONFIRMATION=""
RUN_LIVE="true"
RUN_K8S="false"
RUN_AKS="false"
RUN_EKS="false"
RUN_DRIFT="false"
REUSE_DATA_STACK="true"
NO_DESTROY="false"
ALLOW_DESTROY_PLAN="false"
SEPARATE_CLOUD_RUNS="true"

usage() {
  cat <<'USAGE'
Usage: scripts/dispatch-terraform-manual-validation.sh [options]

Dispatch Terraform Manual Validation runs to GitHub Actions. When --cloud both is
used, this script launches separate aws and azure workflow_dispatch runs by
default so they can execute concurrently and fail independently.

Options:
  --repo <owner/repo>              GitHub repository (default: honua-io/honua-terraform)
  --ref <branch-or-tag>            Git ref to dispatch (default: current git branch, else trunk)
  --cloud <aws|azure|both>         Cloud selection (default: both)
  --deployment-profile <name>      ephemeral or persistent (default: ephemeral)
  --apply-confirmation <value>     Apply confirmation string for persistent runs
  --run-live <true|false>          Run live validation jobs (default: true)
  --run-k8s <true|false>           Run local k8s validation job (default: false)
  --run-aks <true|false>           Run AKS validation job (default: false)
  --run-eks <true|false>           Run EKS validation job (default: false)
  --run-drift <true|false>         Run drift detection job (default: false)
  --reuse-data-stack <true|false>  Reuse shared PostGIS/Redis data stacks across runs (default: true)
  --no-destroy <true|false>        Keep compute resources after validation (default: false)
  --allow-destroy-plan <true|false>
                                   Allow apply when plan includes destroys (default: false)
  --single-run                     Dispatch one combined run for --cloud both
  --help, -h                       Show this help

Notes:
  - GitHub-hosted runners do not preserve /tmp cache files between runs.
  - True CI reuse of PostGIS/Redis requires existing dependency repo vars:
      Azure: HONUA_AZURE_EXISTING_DB_FQDN,
             HONUA_AZURE_EXISTING_DB_CONNECTION_STRING,
             HONUA_AZURE_EXISTING_REDIS_CONNECTION_STRING
      AWS:   HONUA_AWS_EXISTING_DB_ENDPOINT,
             HONUA_AWS_EXISTING_DB_CONNECTION_STRING,
             HONUA_AWS_EXISTING_REDIS_CONNECTION_STRING,
             HONUA_AWS_EXISTING_VPC_ID,
             HONUA_AWS_EXISTING_VPC_CIDR,
             HONUA_AWS_EXISTING_PUBLIC_SUBNET_IDS,
             HONUA_AWS_EXISTING_PRIVATE_SUBNET_IDS
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

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "Required command not found: $1"
    exit 1
  fi
}

validate_boolean() {
  local name="$1"
  local value="$2"

  if [[ "$value" != "true" && "$value" != "false" ]]; then
    log_error "$name must be true or false (got: $value)"
    exit 1
  fi
}

default_ref() {
  local branch=""
  branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -n "$branch" && "$branch" != "HEAD" ]]; then
    printf '%s\n' "$branch"
    return 0
  fi

  printf 'trunk\n'
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        REPO="$2"
        shift 2
        ;;
      --ref)
        REF="$2"
        shift 2
        ;;
      --cloud)
        CLOUD="$2"
        shift 2
        ;;
      --deployment-profile)
        DEPLOYMENT_PROFILE="$2"
        shift 2
        ;;
      --apply-confirmation)
        APPLY_CONFIRMATION="$2"
        shift 2
        ;;
      --run-live)
        RUN_LIVE="$2"
        shift 2
        ;;
      --run-k8s)
        RUN_K8S="$2"
        shift 2
        ;;
      --run-aks)
        RUN_AKS="$2"
        shift 2
        ;;
      --run-eks)
        RUN_EKS="$2"
        shift 2
        ;;
      --run-drift)
        RUN_DRIFT="$2"
        shift 2
        ;;
      --reuse-data-stack)
        REUSE_DATA_STACK="$2"
        shift 2
        ;;
      --no-destroy)
        NO_DESTROY="$2"
        shift 2
        ;;
      --allow-destroy-plan)
        ALLOW_DESTROY_PLAN="$2"
        shift 2
        ;;
      --single-run)
        SEPARATE_CLOUD_RUNS="false"
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

  if [[ -z "$REF" ]]; then
    REF="$(default_ref)"
  fi

  case "$CLOUD" in
    aws|azure|both) ;;
    *)
      log_error "--cloud must be one of: aws, azure, both"
      exit 1
      ;;
  esac

  case "$DEPLOYMENT_PROFILE" in
    ephemeral|persistent) ;;
    *)
      log_error "--deployment-profile must be ephemeral or persistent"
      exit 1
      ;;
  esac

  validate_boolean "--run-live" "$RUN_LIVE"
  validate_boolean "--run-k8s" "$RUN_K8S"
  validate_boolean "--run-aks" "$RUN_AKS"
  validate_boolean "--run-eks" "$RUN_EKS"
  validate_boolean "--run-drift" "$RUN_DRIFT"
  validate_boolean "--reuse-data-stack" "$REUSE_DATA_STACK"
  validate_boolean "--no-destroy" "$NO_DESTROY"
  validate_boolean "--allow-destroy-plan" "$ALLOW_DESTROY_PLAN"
}

load_repo_variables() {
  gh variable list --repo "$REPO" --json name,value --jq '.[] | [.name, .value] | @tsv'
}

load_repo_secret_names() {
  gh secret list --repo "$REPO" | awk 'NR>1 {print $1}'
}

repo_var_value() {
  local name="$1"
  local line=""
  line="$(printf '%s\n' "$REPO_VARIABLES" | awk -F '\t' -v key="$name" '$1 == key { print $2; exit }')"
  printf '%s\n' "$line"
}

repo_secret_exists() {
  local name="$1"
  printf '%s\n' "$REPO_SECRET_NAMES" | awk -v key="$name" '$1 == key { found=1 } END { exit(found ? 0 : 1) }'
}

report_reuse_status() {
  local cloud="$1"
  local missing=()
  local name=""

  if [[ "$REUSE_DATA_STACK" != "true" ]]; then
    log_warn "Data-stack reuse is disabled for this dispatch."
    return
  fi

  case "$cloud" in
    azure)
      if [[ -z "$(repo_var_value "HONUA_AZURE_EXISTING_DB_FQDN")" ]]; then
        missing+=("HONUA_AZURE_EXISTING_DB_FQDN")
      fi
      if ! repo_secret_exists "HONUA_AZURE_EXISTING_DB_CONNECTION_STRING"; then
        missing+=("HONUA_AZURE_EXISTING_DB_CONNECTION_STRING")
      fi
      if ! repo_secret_exists "HONUA_AZURE_EXISTING_REDIS_CONNECTION_STRING"; then
        missing+=("HONUA_AZURE_EXISTING_REDIS_CONNECTION_STRING")
      fi

      if [[ "${#missing[@]}" -eq 0 ]]; then
        log_info "Azure CI data reuse is configured via repo var + secrets; PostGIS/Redis should be reused."
      else
        log_warn "Azure repo-var reuse is not configured. The workflow will fall back to the persisted GitHub Actions cache if a prior reusable Azure data run exists; otherwise this run will reprovision PostGIS/Redis."
        printf '  missing entries: %s\n' "${missing[*]}"
      fi
      ;;
    aws)
      for name in \
        HONUA_AWS_EXISTING_DB_ENDPOINT \
        HONUA_AWS_EXISTING_VPC_ID \
        HONUA_AWS_EXISTING_VPC_CIDR \
        HONUA_AWS_EXISTING_PUBLIC_SUBNET_IDS \
        HONUA_AWS_EXISTING_PRIVATE_SUBNET_IDS; do
        if [[ -z "$(repo_var_value "$name")" ]]; then
          missing+=("$name")
        fi
      done
      if ! repo_secret_exists "HONUA_AWS_EXISTING_DB_CONNECTION_STRING"; then
        missing+=("HONUA_AWS_EXISTING_DB_CONNECTION_STRING")
      fi
      if ! repo_secret_exists "HONUA_AWS_EXISTING_REDIS_CONNECTION_STRING"; then
        missing+=("HONUA_AWS_EXISTING_REDIS_CONNECTION_STRING")
      fi

      if [[ "${#missing[@]}" -eq 0 ]]; then
        log_info "AWS CI data reuse is configured via repo vars + secrets; PostGIS/Redis/VPC should be reused."
      else
        log_warn "AWS repo-var reuse is not configured. The workflow will fall back to the persisted GitHub Actions cache if a prior reusable AWS data run exists; otherwise this run will reprovision VPC/PostGIS/Redis."
        printf '  missing entries: %s\n' "${missing[*]}"
      fi
      ;;
  esac
}

dispatch_run() {
  local cloud="$1"

  log_info "Dispatching $cloud validation on ref $REF"
  gh workflow run "$WORKFLOW" \
    --repo "$REPO" \
    --ref "$REF" \
    -f "cloud=$cloud" \
    -f "deployment_profile=$DEPLOYMENT_PROFILE" \
    -f "apply_confirmation=$APPLY_CONFIRMATION" \
    -f "run_live=$RUN_LIVE" \
    -f "run_k8s=$RUN_K8S" \
    -f "run_aks=$RUN_AKS" \
    -f "run_eks=$RUN_EKS" \
    -f "run_drift=$RUN_DRIFT" \
    -f "reuse_data_stack=$REUSE_DATA_STACK" \
    -f "no_destroy=$NO_DESTROY" \
    -f "allow_destroy_plan=$ALLOW_DESTROY_PLAN"
}

main() {
  require_command gh
  require_command git
  parse_args "$@"

  REPO_VARIABLES="$(load_repo_variables)"
  REPO_SECRET_NAMES="$(load_repo_secret_names)"

  case "$CLOUD" in
    both)
      report_reuse_status "aws"
      report_reuse_status "azure"
      if [[ "$SEPARATE_CLOUD_RUNS" == "true" ]]; then
        dispatch_run "aws"
        dispatch_run "azure"
        log_info "Dispatched separate AWS and Azure runs. They can execute concurrently because the workflow concurrency key now includes the cloud input."
      else
        dispatch_run "both"
        log_info "Dispatched one combined AWS+Azure run."
      fi
      ;;
    aws|azure)
      report_reuse_status "$CLOUD"
      dispatch_run "$CLOUD"
      log_info "Dispatched $CLOUD run."
      ;;
  esac

  log_info "Inspect recent runs with: gh run list --repo $REPO --workflow \"$WORKFLOW\" --branch \"$REF\" --event workflow_dispatch --limit 10"
}

main "$@"
