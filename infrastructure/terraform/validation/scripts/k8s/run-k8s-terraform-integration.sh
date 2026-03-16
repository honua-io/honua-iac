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

CLUSTER_NAME="${K8S_TF_CLUSTER_NAME:-honua-it-$(date -u +%m%d%H%M)}"
CLUSTER_MODE="${K8S_TF_CLUSTER_MODE:-k3d}"
ACCESS_MODE="${K8S_TF_ACCESS_MODE:-ingress}"
KUBE_CONTEXT="${K8S_TF_KUBE_CONTEXT:-}"
HTTP_PORT="${K8S_TF_HTTP_PORT:-8080}"
HTTPS_PORT="${K8S_TF_HTTPS_PORT:-8443}"
API_PORT="${K8S_TF_API_PORT:-6550}"
FORWARD_PORT="${K8S_TF_FORWARD_PORT:-18080}"
NAMESPACE="${K8S_TF_NAMESPACE:-honua}"
OBS_NAMESPACE="${K8S_TF_OBS_NAMESPACE:-honua-observability}"
RELEASE_NAME="${K8S_TF_RELEASE_NAME:-honua}"
INGRESS_HOSTNAME="${K8S_TF_INGRESS_HOSTNAME:-honua.local}"
DEFAULT_HONUA_IMAGE="ghcr.io/honua-io/honua-server:latest"
DEFAULT_HONUA_AOT_IMAGE="ghcr.io/honua-io/honua-server:latest-aot"
USE_AOT="${HONUA_USE_AOT:-false}"
HONUA_IMAGE="${HONUA_K8S_IMAGE:-}"
PREVIOUS_IMAGE="${HONUA_K8S_PREVIOUS_IMAGE:-}"
AUTO_DESTROY=true
QUICK_SCALE=true
CHECK_IDEMPOTENCY=true
CHECK_PROTOCOLS=true
RUN_OBSERVABILITY=true
RUN_DB_RESILIENCE=true
RUN_UPGRADE_ROLLBACK=false
HELM_STATIC_VALIDATE=true
TIMEOUT_SECONDS="${HONUA_K8S_TEST_TIMEOUT_SECONDS:-900}"
LOAD_REQUESTS="${HONUA_K8S_LOAD_REQUESTS:-80}"
LOAD_CONCURRENCY="${HONUA_K8S_LOAD_CONCURRENCY:-20}"
SCALE_TARGET_REPLICAS="${HONUA_K8S_SCALE_TARGET_REPLICAS:-2}"
READY_SLO_SECONDS="${HONUA_READY_SLO_SECONDS:-600}"
MAX_LOAD_ERROR_RATE_PERCENT="${HONUA_MAX_LOAD_ERROR_RATE_PERCENT:-0}"
HELM_CHART_PATH="${HONUA_HELM_CHART_PATH:-}"

TEMP_WORK_ROOT=""
TEMP_REPO_ROOT=""
CLUSTER_CREATED=false
HONUA_APPLIED=false
OBS_APPLIED=false
POSTGIS_APPLIED=false
PORT_FORWARD_PID=""
PORT_FORWARD_LOG=""

HONUA_IMAGE_REPOSITORY=""
HONUA_IMAGE_TAG=""
PREVIOUS_IMAGE_REPOSITORY=""
PREVIOUS_IMAGE_TAG=""
HONUA_IMAGE_PULL_SECRET_NAME="${HONUA_IMAGE_PULL_SECRET_NAME:-}"
HONUA_IMAGE_PULL_SECRET_SERVER="${HONUA_IMAGE_PULL_SECRET_SERVER:-}"
HONUA_IMAGE_PULL_SECRET_USERNAME="${HONUA_IMAGE_PULL_SECRET_USERNAME:-}"
HONUA_IMAGE_PULL_SECRET_PASSWORD="${HONUA_IMAGE_PULL_SECRET_PASSWORD:-}"
HONUA_DEPLOYMENT_NAME=""
HONUA_SERVICE_NAME=""
K8S_HELPER_DIR=""
K8S_ADMIN_PASSWORD=""
K8S_MASTER_KEY=""

if [[ -n "${KUBECONFIG:-}" ]]; then
  KUBECONFIG_PATH="${KUBECONFIG%%:*}"
else
  KUBECONFIG_PATH="$HOME/.kube/config"
fi

usage() {
  cat <<USAGE
Run live Kubernetes integration tests for Honua Helm deployment and observability Terraform module.

Usage:
  ./infrastructure/terraform/validation/scripts/k8s/run-k8s-terraform-integration.sh [options]

Options:
  --cluster-name <name>                Cluster name (k3d name or managed cluster label)
  --cluster-mode <k3d|external>        Cluster mode (default: k3d)
  --access-mode <ingress|port-forward> Access mode for HTTP checks (default: ingress)
  --kubeconfig <path>                  Kubeconfig path for external mode
  --kube-context <name>                Optional kube context to select
  --http-port <port>                   Local HTTP port mapped to ingress (default: 8080)
  --https-port <port>                  Local HTTPS port mapped to ingress (default: 8443)
  --api-port <port>                    k3d API port (default: 6550)
  --forward-port <port>                Local port used for service port-forward mode (default: 18080)
  --namespace <name>                   Namespace for Honua + PostGIS (default: honua)
  --observability-namespace <name>     Namespace for observability stack (default: honua-observability)
  --release-name <name>                Helm release name for Honua (default: honua)
  --ingress-host <hostname>            Ingress host header used for checks (default: honua.local)
  --aot                                Use latest-aot when image is default
  --image <repo:tag>                   Honua container image
  --previous-image <repo:tag>          Previous image used for upgrade/rollback validation
  --upgrade-rollback                   Enable upgrade/rollback validation sequence
  --timeout-seconds <n>                Timeout for readiness/rollout checks (default: 900)
  --max-ready-seconds <n>              Ready SLO threshold (default: 600)
  --max-load-error-rate <percent>      Max allowed load error rate (default: 0)
  --skip-idempotency                   Skip post-apply zero-drift plan assertion
  --skip-protocol-checks               Skip REST/OGC/OData/admin auth + admin CRUD/query smoke checks
  --skip-observability                 Skip Terraform observability module apply checks
  --skip-db-resilience                 Skip DB backup/restore drill
  --skip-helm-static-validation        Skip helm lint/template/kubeconform checks
  --no-scale-check                     Skip quick deployment scale check
  --no-destroy                         Keep cluster/resources after test run
  --help, -h                           Show this help

Optional environment variables:
  HONUA_K8S_IMAGE                      Honua image for Helm deployment
  HONUA_K8S_PREVIOUS_IMAGE             Previous image for upgrade/rollback validation
  HONUA_KUBECONFORM_IMAGE              Kubeconform image override for Helm manifest validation
  HONUA_ADMIN_PASSWORD                 Admin password for Helm chart secret
  SECURITY_MASTER_KEY                  Master key for app startup
  HONUA_PLATFORM_VALIDATION_SCRIPT     Optional path to honua-server/scripts/run-cloud-post-apply-validation.sh
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
source "$SCRIPT_DIR/lib/validation.sh"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "Required command not found: $1"
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-name)
        CLUSTER_NAME="$2"
        shift 2
        ;;
      --cluster-mode)
        CLUSTER_MODE="$2"
        shift 2
        ;;
      --access-mode)
        ACCESS_MODE="$2"
        shift 2
        ;;
      --kubeconfig)
        KUBECONFIG_PATH="$2"
        shift 2
        ;;
      --kube-context)
        KUBE_CONTEXT="$2"
        shift 2
        ;;
      --http-port)
        HTTP_PORT="$2"
        shift 2
        ;;
      --https-port)
        HTTPS_PORT="$2"
        shift 2
        ;;
      --api-port)
        API_PORT="$2"
        shift 2
        ;;
      --forward-port)
        FORWARD_PORT="$2"
        shift 2
        ;;
      --namespace)
        NAMESPACE="$2"
        shift 2
        ;;
      --observability-namespace)
        OBS_NAMESPACE="$2"
        shift 2
        ;;
      --release-name)
        RELEASE_NAME="$2"
        shift 2
        ;;
      --ingress-host)
        INGRESS_HOSTNAME="$2"
        shift 2
        ;;
      --aot)
        USE_AOT=true
        shift
        ;;
      --image)
        HONUA_IMAGE="$2"
        shift 2
        ;;
      --previous-image)
        PREVIOUS_IMAGE="$2"
        shift 2
        ;;
      --upgrade-rollback)
        RUN_UPGRADE_ROLLBACK=true
        shift
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
      --skip-idempotency)
        CHECK_IDEMPOTENCY=false
        shift
        ;;
      --skip-protocol-checks)
        CHECK_PROTOCOLS=false
        shift
        ;;
      --skip-observability)
        RUN_OBSERVABILITY=false
        shift
        ;;
      --skip-db-resilience)
        RUN_DB_RESILIENCE=false
        shift
        ;;
      --skip-helm-static-validation)
        HELM_STATIC_VALIDATE=false
        shift
        ;;
      --no-scale-check)
        QUICK_SCALE=false
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

  if [[ "$CLUSTER_MODE" != "k3d" && "$CLUSTER_MODE" != "external" ]]; then
    log_error "Invalid --cluster-mode value: $CLUSTER_MODE"
    exit 1
  fi

  if [[ "$ACCESS_MODE" != "ingress" && "$ACCESS_MODE" != "port-forward" ]]; then
    log_error "Invalid --access-mode value: $ACCESS_MODE"
    exit 1
  fi
}

main() {
  parse_args "$@"
  apply_aot_mode
  validate_requested_images

  require_command docker
  require_command kubectl
  require_command helm
  require_command terraform
  require_command curl

  if [[ "$CLUSTER_MODE" == "k3d" ]]; then
    require_command k3d
  fi

  export KUBECONFIG="$KUBECONFIG_PATH"

  resolve_helm_chart_path
  resolve_k8s_helper_dir
  resolve_secret_values

  parse_image "$HONUA_IMAGE" HONUA_IMAGE_REPOSITORY HONUA_IMAGE_TAG
  if [[ -n "$PREVIOUS_IMAGE" ]]; then
    parse_image "$PREVIOUS_IMAGE" PREVIOUS_IMAGE_REPOSITORY PREVIOUS_IMAGE_TAG
  fi

  run_helm_static_validation
  prepare_tf_workspace

  trap cleanup EXIT

  log_info "Starting Kubernetes integration test"
  log_info "Cluster mode: $CLUSTER_MODE"
  log_info "Cluster name: $CLUSTER_NAME"
  if [[ "$ACCESS_MODE" == "port-forward" ]]; then
    log_info "HTTP endpoint: http://localhost:$FORWARD_PORT (port-forward)"
  else
    log_info "HTTP endpoint: http://localhost:$HTTP_PORT (Host: $INGRESS_HOSTNAME)"
  fi
  log_info "Namespace: $NAMESPACE"
  log_info "Observability namespace: $OBS_NAMESPACE"
  log_info "AOT mode: $USE_AOT"
  log_info "Honua image: $HONUA_IMAGE"
  if [[ -n "$PREVIOUS_IMAGE" ]]; then
    log_info "Previous image: $PREVIOUS_IMAGE"
  fi
  log_info "Ready SLO seconds: $READY_SLO_SECONDS"
  log_info "Max load error rate: ${MAX_LOAD_ERROR_RATE_PERCENT}%"
  log_info "Kubeconfig path: $KUBECONFIG_PATH"
  log_info "Helper scripts path: $K8S_HELPER_DIR"
  if [[ -n "$KUBE_CONTEXT" ]]; then
    log_info "Kube context: $KUBE_CONTEXT"
  fi

  create_cluster
  deploy_honua_stack

  if [[ "$RUN_OBSERVABILITY" == "true" ]]; then
    apply_observability_stack
  fi

  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_HOST="honua-postgis" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_PORT="5432" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_NAME="honua" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_USERNAME="honua" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_PASSWORD="honua" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_SSL_MODE="Disable" \
  HONUA_PLATFORM_VALIDATION_PUBLISH_DB_SSL_REQUIRED="false" \
  VERIFICATION_TIMEOUT="$TIMEOUT_SECONDS" \
  run_honua_platform_post_apply_validation "$(http_base_url)" "kubernetes"

  log_info "Kubernetes integration checks completed successfully"
}

main "$@"
