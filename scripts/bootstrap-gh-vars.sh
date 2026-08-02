#!/usr/bin/env bash

set -euo pipefail

REPO="honua-io/honua-terraform"
SOURCE_REPO="honua-io/honua-server"
DRY_RUN=false
SYNC_STACK_VARS=true
USE_AOT=true

GENERIC_IMAGE=""
AWS_ECS_IMAGE=""
AWS_SERVERLESS_IMAGE=""
ACA_IMAGE=""
FUNCTIONS_IMAGE=""
K8S_IMAGE=""
AKS_IMAGE=""
EKS_IMAGE=""

ECR_REGION=""
ECR_REPOSITORY=""
ACR_LOGIN_SERVER=""
ACR_REPOSITORY=""
AZURE_REGISTRY_RESOURCE_ID=""

usage() {
  cat <<'EOF'
Usage:
  scripts/bootstrap-gh-vars.sh [options]

Options:
  --repo <owner/repo>               Target repo for GitHub Actions variables
                                    Default: honua-io/honua-terraform
  --source-repo <owner/repo>        Repo to read registry publish vars from
                                    Default: honua-io/honua-server
  --generic-image <ref>             Base public image used for k8s and ACA fallback
                                    Default: ghcr.io/honua-io/honua-server:latest-aot
  --aws-ecs-image <ref>             Explicit ECS image override
  --aws-serverless-image <ref>      Explicit Lambda image override
  --aca-image <ref>                 Explicit ACA image override
  --functions-image <ref>           Explicit Azure Functions image override
  --k8s-image <ref>                 Explicit k8s image override
  --aks-image <ref>                 Explicit AKS image override
  --eks-image <ref>                 Explicit EKS image override
  --ecr-region <region>             ECR region override
  --ecr-repository <name>           ECR repository override
  --acr-login-server <host>         ACR login server override
  --acr-repository <name>           ACR repository override
  --use-jit                         Use latest-ecs/latest-lambda/latest-functions tags
  --no-stack-sync                   Do not update validation stack selection vars
  --dry-run                         Print values without writing GitHub variables
  -h, --help                        Show this help

Notes:
  - Secrets remain in GitHub Secrets. This helper only manages repo variables.
  - ECS/Lambda images are derived from the honua-server ECR publish lane when AWS
    credentials are available in the current shell.
  - AWS ECS resolves to the `*-ecs-aot` image family and its Terraform default
    targets x86_64. Lambda resolves to the `*-lambda-aot` image family and
    targets arm64 by default.
  - ACA/Functions images are derived from ACR when ACR is configured in the
    source repo.
  - Azure Container Apps and Azure Functions should use amd64 cloud images.
    AKS should use the generic multi-arch image family so Arm node pools can
    pull arm64 variants automatically.
  - AKS and EKS can be pinned independently when cloud-native registry lanes
    are configured; otherwise they fall back to the shared generic image.
  - GHCR is kept as the generic/k8s fallback and as a temporary ACA fallback
    when the Azure cloud-native registry lane is not configured yet.
EOF
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "error: required command not found: $name" >&2
    exit 1
  fi
}

assert_gh_ready() {
  require_command gh
  if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh CLI not authenticated; run 'gh auth login'" >&2
    exit 1
  fi
}

log_info() {
  echo "[INFO] $1"
}

log_warn() {
  echo "[WARN] $1" >&2
}

declare -A SOURCE_VARS=()

load_source_vars() {
  local row

  while IFS=$'\t' read -r name value; do
    [[ -n "${name:-}" ]] || continue
    SOURCE_VARS["$name"]="$value"
  done < <(gh variable list --repo "$SOURCE_REPO" --json name,value --jq '.[] | [.name, .value] | @tsv')
}

get_source_var() {
  local name="$1"
  printf '%s' "${SOURCE_VARS[$name]:-}"
}

resolve_generic_image() {
  local generic_tag="latest-aot"
  if [[ "$USE_AOT" != "true" ]]; then
    generic_tag="latest"
  fi

  if [[ -z "$GENERIC_IMAGE" ]]; then
    GENERIC_IMAGE="ghcr.io/honua-io/honua-server:${generic_tag}"
  fi

  if [[ -z "$K8S_IMAGE" ]]; then
    K8S_IMAGE="$GENERIC_IMAGE"
  fi
}

resolve_aws_ecs_image() {
  local ecs_tag="latest-ecs-aot"
  local account_id=""

  if [[ -n "$AWS_ECS_IMAGE" ]]; then
    return 0
  fi

  if [[ "$USE_AOT" != "true" ]]; then
    ecs_tag="latest-ecs"
  fi

  if [[ -z "$ECR_REGION" ]]; then
    ECR_REGION="$(get_source_var AWS_ECR_REGION)"
  fi

  if [[ -z "$ECR_REPOSITORY" ]]; then
    ECR_REPOSITORY="$(get_source_var AWS_ECR_REPOSITORY)"
  fi

  if [[ -z "$ECR_REPOSITORY" ]]; then
    ECR_REPOSITORY="honua-server"
  fi

  if [[ -n "$ECR_REGION" ]] && command -v aws >/dev/null 2>&1; then
    if account_id="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
      if aws ecr describe-images \
        --region "$ECR_REGION" \
        --repository-name "$ECR_REPOSITORY" \
        --image-ids imageTag="$ecs_tag" >/dev/null 2>&1; then
        AWS_ECS_IMAGE="${account_id}.dkr.ecr.${ECR_REGION}.amazonaws.com/${ECR_REPOSITORY}:${ecs_tag}"
        return 0
      fi

      log_warn "ECR image tag '$ecs_tag' was not found in ${account_id}.dkr.ecr.${ECR_REGION}.amazonaws.com/${ECR_REPOSITORY}; leaving HONUA_AWS_ECS_IMAGE unset."
      return 0
    fi
  fi

  if [[ -n "$ECR_REGION" ]]; then
    log_warn "AWS credentials are not available in the current shell; leaving HONUA_AWS_ECS_IMAGE unset."
  else
    log_warn "AWS_ECR_REGION is not configured in $SOURCE_REPO; leaving HONUA_AWS_ECS_IMAGE unset."
  fi
}

resolve_aws_serverless_image() {
  local lambda_tag="latest-lambda-aot-arm64"
  local account_id=""

  if [[ -n "$AWS_SERVERLESS_IMAGE" ]]; then
    return 0
  fi

  if [[ "$USE_AOT" != "true" ]]; then
    lambda_tag="latest-lambda-arm64"
  fi

  if [[ -z "$ECR_REGION" ]]; then
    ECR_REGION="$(get_source_var AWS_ECR_REGION)"
  fi

  if [[ -z "$ECR_REPOSITORY" ]]; then
    ECR_REPOSITORY="$(get_source_var AWS_ECR_REPOSITORY)"
  fi

  if [[ -z "$ECR_REPOSITORY" ]]; then
    ECR_REPOSITORY="honua-server"
  fi

  if [[ -z "$ECR_REGION" ]]; then
    log_warn "AWS_ECR_REGION is not configured in $SOURCE_REPO; skipping Lambda image variable."
    return 0
  fi

  if ! command -v aws >/dev/null 2>&1; then
    log_warn "aws CLI is not available; skipping Lambda image variable."
    return 0
  fi

  if ! account_id="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
    log_warn "AWS credentials are not available in the current shell; skipping Lambda image variable."
    return 0
  fi

  if ! aws ecr describe-images \
    --region "$ECR_REGION" \
    --repository-name "$ECR_REPOSITORY" \
    --image-ids imageTag="$lambda_tag" >/dev/null 2>&1; then
    log_warn "ECR image tag '$lambda_tag' was not found in ${account_id}.dkr.ecr.${ECR_REGION}.amazonaws.com/${ECR_REPOSITORY}; skipping Lambda image variable."
    return 0
  fi

  AWS_SERVERLESS_IMAGE="${account_id}.dkr.ecr.${ECR_REGION}.amazonaws.com/${ECR_REPOSITORY}:${lambda_tag}"
}

resolve_azure_aca_image() {
  local aca_tag="latest-aot"

  if [[ -n "$ACA_IMAGE" ]]; then
    return 0
  fi

  if [[ "$USE_AOT" != "true" ]]; then
    aca_tag="latest"
  fi

  if [[ -z "$ACR_LOGIN_SERVER" ]]; then
    ACR_LOGIN_SERVER="$(get_source_var ACR_LOGIN_SERVER)"
  fi

  if [[ -z "$ACR_REPOSITORY" ]]; then
    ACR_REPOSITORY="$(get_source_var ACR_REPOSITORY)"
  fi

  if [[ -z "$ACR_REPOSITORY" ]]; then
    ACR_REPOSITORY="honua-server"
  fi

  if [[ -n "$ACR_LOGIN_SERVER" ]]; then
    ACA_IMAGE="${ACR_LOGIN_SERVER}/${ACR_REPOSITORY}:${aca_tag}"
    return 0
  fi

  log_warn "ACR_LOGIN_SERVER is not configured in $SOURCE_REPO; falling back to generic ACA image."
  ACA_IMAGE="$GENERIC_IMAGE"
}

resolve_azure_functions_image() {
  local functions_tag="latest-functions-aot"

  if [[ -n "$FUNCTIONS_IMAGE" ]]; then
    return 0
  fi

  if [[ "$USE_AOT" != "true" ]]; then
    functions_tag="latest-functions"
  fi

  if [[ -z "$ACR_LOGIN_SERVER" ]]; then
    ACR_LOGIN_SERVER="$(get_source_var ACR_LOGIN_SERVER)"
  fi

  if [[ -z "$ACR_REPOSITORY" ]]; then
    ACR_REPOSITORY="$(get_source_var ACR_REPOSITORY)"
  fi

  if [[ -z "$ACR_REPOSITORY" ]]; then
    ACR_REPOSITORY="honua-server"
  fi

  if [[ -z "$ACR_LOGIN_SERVER" ]]; then
    log_warn "ACR_LOGIN_SERVER is not configured in $SOURCE_REPO; leaving HONUA_FUNCTIONS_IMAGE unset."
    return 0
  fi

  FUNCTIONS_IMAGE="${ACR_LOGIN_SERVER}/${ACR_REPOSITORY}:${functions_tag}"
}

resolve_azure_aks_image() {
  local aks_tag="latest-aot"

  if [[ -n "$AKS_IMAGE" ]]; then
    return 0
  fi

  if [[ "$USE_AOT" != "true" ]]; then
    aks_tag="latest"
  fi

  if [[ -z "$ACR_LOGIN_SERVER" ]]; then
    ACR_LOGIN_SERVER="$(get_source_var ACR_LOGIN_SERVER)"
  fi

  if [[ -z "$ACR_REPOSITORY" ]]; then
    ACR_REPOSITORY="$(get_source_var ACR_REPOSITORY)"
  fi

  if [[ -z "$ACR_REPOSITORY" ]]; then
    ACR_REPOSITORY="honua-server"
  fi

  if [[ -n "$ACR_LOGIN_SERVER" ]]; then
    AKS_IMAGE="${ACR_LOGIN_SERVER}/${ACR_REPOSITORY}:${aks_tag}"
    return 0
  fi

  log_warn "ACR_LOGIN_SERVER is not configured in $SOURCE_REPO; falling back to generic AKS image."
  AKS_IMAGE="$K8S_IMAGE"
}

resolve_azure_registry_resource_id() {
  local registry_name=""

  if [[ -n "$AZURE_REGISTRY_RESOURCE_ID" ]]; then
    return 0
  fi

  if [[ -z "$ACR_LOGIN_SERVER" ]]; then
    ACR_LOGIN_SERVER="$(get_source_var ACR_LOGIN_SERVER)"
  fi

  if [[ -z "$ACR_LOGIN_SERVER" ]]; then
    return 0
  fi

  registry_name="${ACR_LOGIN_SERVER%%.*}"
  if [[ -z "$registry_name" ]]; then
    return 0
  fi

  if command -v az >/dev/null 2>&1; then
    AZURE_REGISTRY_RESOURCE_ID="$(az acr show --name "$registry_name" --query id -o tsv 2>/dev/null || true)"
  fi
}

resolve_aws_eks_image() {
  local eks_tag="latest-aot"
  local account_id=""

  if [[ -n "$EKS_IMAGE" ]]; then
    return 0
  fi

  if [[ "$USE_AOT" != "true" ]]; then
    eks_tag="latest"
  fi

  if [[ -z "$ECR_REGION" ]]; then
    ECR_REGION="$(get_source_var AWS_ECR_REGION)"
  fi

  if [[ -z "$ECR_REPOSITORY" ]]; then
    ECR_REPOSITORY="$(get_source_var AWS_ECR_REPOSITORY)"
  fi

  if [[ -z "$ECR_REPOSITORY" ]]; then
    ECR_REPOSITORY="honua-server"
  fi

  if [[ -n "$ECR_REGION" ]] && command -v aws >/dev/null 2>&1; then
    if account_id="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
      if aws ecr describe-images \
        --region "$ECR_REGION" \
        --repository-name "$ECR_REPOSITORY" \
        --image-ids imageTag="$eks_tag" >/dev/null 2>&1; then
        EKS_IMAGE="${account_id}.dkr.ecr.${ECR_REGION}.amazonaws.com/${ECR_REPOSITORY}:${eks_tag}"
        return 0
      fi

      log_warn "ECR image tag '$eks_tag' was not found in ${account_id}.dkr.ecr.${ECR_REGION}.amazonaws.com/${ECR_REPOSITORY}; falling back to generic EKS image."
      EKS_IMAGE="$K8S_IMAGE"
      return 0
    fi
  fi

  if [[ -n "$ECR_REGION" ]]; then
    log_warn "AWS credentials are not available in the current shell; falling back to generic EKS image."
  else
    log_warn "AWS_ECR_REGION is not configured in $SOURCE_REPO; falling back to generic EKS image."
  fi

  EKS_IMAGE="$K8S_IMAGE"
}

set_variable() {
  local key="$1"
  local value="$2"

  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[DRY-RUN] %s=%s\n' "$key" "$value"
    return 0
  fi

  gh variable set "$key" --repo "$REPO" --body "$value" >/dev/null
  printf '[SET] %s=%s\n' "$key" "$value"
}

clear_variable() {
  local key="$1"

  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[DRY-RUN] clear %s\n' "$key"
    return 0
  fi

  gh variable delete "$key" --repo "$REPO" >/dev/null 2>&1 || true
  printf '[CLEAR] %s\n' "$key"
}

sync_stack_vars() {
  local aws_stack=""
  local azure_stack=""

  if [[ -n "$AWS_ECS_IMAGE" && -n "$AWS_SERVERLESS_IMAGE" ]]; then
    aws_stack="both"
  elif [[ -n "$AWS_ECS_IMAGE" ]]; then
    aws_stack="ecs"
  elif [[ -n "$AWS_SERVERLESS_IMAGE" ]]; then
    aws_stack="serverless"
  fi

  if [[ -n "$ACA_IMAGE" && -n "$FUNCTIONS_IMAGE" ]]; then
    azure_stack="both"
  elif [[ -n "$ACA_IMAGE" ]]; then
    azure_stack="aca"
  elif [[ -n "$FUNCTIONS_IMAGE" ]]; then
    azure_stack="functions"
  fi

  if [[ -n "$aws_stack" ]]; then
    set_variable "HONUA_AWS_VALIDATION_STACK" "$aws_stack"
  else
    clear_variable "HONUA_AWS_VALIDATION_STACK"
  fi

  if [[ -n "$azure_stack" ]]; then
    set_variable "HONUA_AZURE_VALIDATION_STACK" "$azure_stack"
  else
    clear_variable "HONUA_AZURE_VALIDATION_STACK"
  fi

  if [[ -n "$ECR_REGION" ]]; then
    set_variable "HONUA_AWS_VALIDATION_REGION" "$ECR_REGION"
  else
    clear_variable "HONUA_AWS_VALIDATION_REGION"
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        REPO="${2:-}"
        shift 2
        ;;
      --source-repo)
        SOURCE_REPO="${2:-}"
        shift 2
        ;;
      --generic-image)
        GENERIC_IMAGE="${2:-}"
        shift 2
        ;;
      --aws-ecs-image)
        AWS_ECS_IMAGE="${2:-}"
        shift 2
        ;;
      --aws-serverless-image)
        AWS_SERVERLESS_IMAGE="${2:-}"
        shift 2
        ;;
      --aca-image)
        ACA_IMAGE="${2:-}"
        shift 2
        ;;
      --functions-image)
        FUNCTIONS_IMAGE="${2:-}"
        shift 2
        ;;
      --k8s-image)
        K8S_IMAGE="${2:-}"
        shift 2
        ;;
      --aks-image)
        AKS_IMAGE="${2:-}"
        shift 2
        ;;
      --eks-image)
        EKS_IMAGE="${2:-}"
        shift 2
        ;;
      --ecr-region)
        ECR_REGION="${2:-}"
        shift 2
        ;;
      --ecr-repository)
        ECR_REPOSITORY="${2:-}"
        shift 2
        ;;
      --acr-login-server)
        ACR_LOGIN_SERVER="${2:-}"
        shift 2
        ;;
      --acr-repository)
        ACR_REPOSITORY="${2:-}"
        shift 2
        ;;
      --use-jit)
        USE_AOT=false
        shift
        ;;
      --no-stack-sync)
        SYNC_STACK_VARS=false
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown option '$1'" >&2
        usage
        exit 1
        ;;
    esac
  done

  assert_gh_ready
  load_source_vars
  resolve_generic_image
  resolve_aws_ecs_image
  resolve_aws_serverless_image
  resolve_azure_aca_image
  resolve_azure_functions_image
  resolve_azure_aks_image
  resolve_azure_registry_resource_id
  resolve_aws_eks_image

  set_variable "HONUA_AWS_ECS_IMAGE" "$AWS_ECS_IMAGE"
  set_variable "HONUA_ACA_IMAGE" "$ACA_IMAGE"
  set_variable "HONUA_K8S_IMAGE" "$K8S_IMAGE"
  set_variable "HONUA_AKS_IMAGE" "$AKS_IMAGE"
  set_variable "HONUA_EKS_IMAGE" "$EKS_IMAGE"

  if [[ -n "$AZURE_REGISTRY_RESOURCE_ID" ]]; then
    set_variable "HONUA_AZURE_REGISTRY_RESOURCE_ID" "$AZURE_REGISTRY_RESOURCE_ID"
  else
    clear_variable "HONUA_AZURE_REGISTRY_RESOURCE_ID"
  fi

  if [[ -n "$AWS_SERVERLESS_IMAGE" ]]; then
    set_variable "HONUA_AWS_SERVERLESS_IMAGE" "$AWS_SERVERLESS_IMAGE"
  else
    clear_variable "HONUA_AWS_SERVERLESS_IMAGE"
  fi

  if [[ -n "$FUNCTIONS_IMAGE" ]]; then
    set_variable "HONUA_FUNCTIONS_IMAGE" "$FUNCTIONS_IMAGE"
  else
    clear_variable "HONUA_FUNCTIONS_IMAGE"
  fi

  if [[ "$SYNC_STACK_VARS" == "true" ]]; then
    sync_stack_vars
  fi

  log_info "Terraform validation repo-variable bootstrap complete for $REPO"
}

main "$@"
