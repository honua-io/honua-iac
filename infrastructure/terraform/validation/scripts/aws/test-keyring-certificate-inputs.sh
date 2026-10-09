#!/usr/bin/env bash
# Hermetic runner contract: no AWS calls, applies, Docker daemon or secret values.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HONUA_AWS_OPERATION_KEY_RING_CERTIFICATE_SECRET_ARN="arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
export HONUA_AWS_OPERATION_KEY_RING_CERTIFICATE_SECRET_KMS_KEY_ARN="arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002"
source "$TEST_DIR/run-aws-terraform-integration.sh"
STACK=ecs
ECS_IMAGE="ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
validate_requested_images
if (unset HONUA_AWS_OPERATION_KEY_RING_CERTIFICATE_SECRET_ARN; validate_requested_images) >/dev/null 2>&1; then
  echo "Missing ECS certificate ARN was accepted" >&2
  exit 1
fi
STACK=serverless
SERVERLESS_IMAGE="123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
validate_requested_images
if (unset HONUA_AWS_OPERATION_KEY_RING_CERTIFICATE_SECRET_ARN; validate_requested_images) >/dev/null 2>&1; then
  echo "Missing serverless certificate ARN was accepted" >&2
  exit 1
fi
STACK=data
(unset HONUA_AWS_OPERATION_KEY_RING_CERTIFICATE_SECRET_ARN; validate_requested_images)
HONUA_ADMIN_PASSWORD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HONUA_DB_PASSWORD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HTTP_INGRESS_CIDR=127.0.0.1/32
ECS_NAME_PREFIX=keyring-test
SERVERLESS_NAME_PREFIX=keyring-test
ensure_existing_vpc_private_egress() { :; }
set_serverless_tf_vars
[[ "$TF_VAR_operation_key_ring_certificate_secret_arn" == "$HONUA_AWS_OPERATION_KEY_RING_CERTIFICATE_SECRET_ARN" ]]
[[ "$TF_VAR_operation_key_ring_certificate_secret_kms_key_arn" == "$HONUA_AWS_OPERATION_KEY_RING_CERTIFICATE_SECRET_KMS_KEY_ARN" ]]
set_ecs_tf_vars
terraform() {
  [[ "$TF_VAR_operation_key_ring_certificate_secret_arn" == "$HONUA_AWS_OPERATION_KEY_RING_CERTIFICATE_SECRET_ARN" ]]
  [[ "$TF_VAR_operation_key_ring_certificate_secret_kms_key_arn" == "$HONUA_AWS_OPERATION_KEY_RING_CERTIFICATE_SECRET_KMS_KEY_ARN" ]]
}
TEMP_TF_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_TF_ROOT"' EXIT
mkdir -p "$TEMP_TF_ROOT/terraform"
run_tf version
# Emulate Docker's -e NAME forwarding and then check the actual forwarded values.
docker() {
  local arg certificate_seen=false key_seen=false
  while (( $# )); do
    arg="$1"; shift
    if [[ "$arg" == -e ]]; then
      case "$1" in
        TF_VAR_operation_key_ring_certificate_secret_arn)
          [[ "${!1}" == "$HONUA_AWS_OPERATION_KEY_RING_CERTIFICATE_SECRET_ARN" ]]
          certificate_seen=true ;;
        TF_VAR_operation_key_ring_certificate_secret_kms_key_arn)
          [[ "${!1}" == "$HONUA_AWS_OPERATION_KEY_RING_CERTIFICATE_SECRET_KMS_KEY_ARN" ]]
          key_seen=true ;;
      esac
      shift
    fi
  done
  [[ "$certificate_seen" == true && "$key_seen" == true ]]
}
USE_DOCKER_TF=true
run_tf version
printf 'PASS: required ECS/serverless certificate input and native/Docker ARN forwarding\n'
