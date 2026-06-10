#!/usr/bin/env bash

if [[ -n "${TF_SECRET_CATALOG_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
TF_SECRET_CATALOG_LOADED=1

TF_PASS_DEFAULT_PREFIX="${TF_PASS_DEFAULT_PREFIX:-honua/terraform}"

TERRAFORM_ESSENTIAL_SECRETS=(
  ARM_CLIENT_ID
  ARM_CLIENT_SECRET
  ARM_TENANT_ID
  ARM_SUBSCRIPTION_ID
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  HONUA_ADMIN_PASSWORD
  HONUA_DB_PASSWORD
)

TERRAFORM_OPTIONAL_SECRETS=(
  AWS_SESSION_TOKEN
)

CLOUD_DEMO_SECRETS=(
  HONUA_CLOUD_DEMO_API_KEY
  HONUA_CLOUD_DEMO_BEARER_TOKEN
  HONUA_CLOUD_DEMO_WRITE_TOKEN
  HONUA_CLOUD_DEMO_RESET_TOKEN
  HONUA_CLOUD_DEMO_RESET_URL
  VITE_HONUA_QUICKSTART_API_KEY
  VITE_HONUA_QUICKSTART_BEARER_TOKEN
  VITE_HONUA_SERVICE_EXPLORER_API_KEY
  VITE_HONUA_SERVICE_EXPLORER_BEARER_TOKEN
  VITE_HONUA_25D_API_KEY
  HONUA_DEMO_API_KEY
  HONUA_DEMO_BEARER_TOKEN
  VITE_HONUA_EDIT_WORKFLOW_API_KEY
  VITE_HONUA_EDIT_WORKFLOW_BEARER_TOKEN
)

PUBLISH_SECRETS=(
  ARM_CLIENT_ID
  ARM_CLIENT_SECRET
  ARM_TENANT_ID
  ARM_SUBSCRIPTION_ID
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  AWS_SESSION_TOKEN
)

ALL_KNOWN_SECRETS=(
  ARM_CLIENT_ID
  ARM_CLIENT_SECRET
  ARM_TENANT_ID
  ARM_SUBSCRIPTION_ID
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  AWS_SESSION_TOKEN
  HONUA_ADMIN_PASSWORD
  HONUA_DB_PASSWORD
  "${CLOUD_DEMO_SECRETS[@]}"
)

tf_secret_contains() {
  local needle="$1"
  shift || true

  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done

  return 1
}

tf_secret_scope_keys() {
  local scope="${1:-terraform}"

  case "$scope" in
    terraform)
      printf '%s\n' "${TERRAFORM_ESSENTIAL_SECRETS[@]}" "${TERRAFORM_OPTIONAL_SECRETS[@]}"
      ;;
    cloud-demo)
      printf '%s\n' "${CLOUD_DEMO_SECRETS[@]}"
      ;;
    publish)
      printf '%s\n' "${PUBLISH_SECRETS[@]}"
      ;;
    all)
      printf '%s\n' "${ALL_KNOWN_SECRETS[@]}"
      ;;
    *)
      echo "error: unknown secret scope '$scope'" >&2
      return 1
      ;;
  esac
}

tf_secret_scope_required_keys() {
  local scope="${1:-terraform}"

  case "$scope" in
    terraform)
      printf '%s\n' "${TERRAFORM_ESSENTIAL_SECRETS[@]}"
      ;;
    cloud-demo|publish|all)
      ;;
    *)
      echo "error: unknown secret scope '$scope'" >&2
      return 1
      ;;
  esac
}

tf_secret_value_is_present() {
  local value="${1-}"
  local placeholder_regex='^<[^>]+>$'

  if [[ -z "$value" ]]; then
    return 1
  fi

  if [[ "$value" =~ $placeholder_regex ]]; then
    return 1
  fi

  return 0
}
