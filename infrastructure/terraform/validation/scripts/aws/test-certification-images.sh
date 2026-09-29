#!/usr/bin/env bash
# Hermetic input and orchestration tests. Not a live serving/rollback receipt.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../shared/certification-images.sh"
old="registry.example/honua@sha256:$(printf 'a%.0s' {1..64})"
new="registry.example/honua@sha256:$(printf 'b%.0s' {1..64})"
require_revision_pair "$old" "$new"
for invalid in '' 'registry.example/honua:latest-lambda-aot-arm64' 'registry.example/honua:v1.0.0' 'registry.example/honua' 'registry.example/honua@sha256:abc'; do
  if require_digest_image fixture "$invalid" 2>/dev/null; then
    echo "Accepted unpinned fixture: $invalid" >&2; exit 1
  fi
done
if require_revision_pair "$old" "other.example/honua@${old##*@}" 2>/dev/null; then
  echo 'Accepted identical bytes under another repository name' >&2; exit 1
fi
source "$TEST_DIR/run-aws-terraform-integration.sh"
RUN_UPGRADE_ROLLBACK=true
STACK=both
ECS_IMAGE="$new"
ECS_PREVIOUS_IMAGE="$old"
SERVERLESS_IMAGE="$new"
SERVERLESS_PREVIOUS_IMAGE="$old"
validate_requested_images
USE_AOT=true
apply_aot_mode
[[ "$ECS_IMAGE" == "$new" && "$SERVERLESS_IMAGE" == "$new" ]]
if ( ECS_PREVIOUS_IMAGE='registry.example/honua:latest'; validate_requested_images ) 2>/dev/null; then
  echo 'Mutable ECS N-1 reached orchestration' >&2; exit 1
fi
if ( SERVERLESS_PREVIOUS_IMAGE='registry.example/honua:latest'; validate_requested_images ) 2>/dev/null; then
  echo 'Mutable Lambda N-1 reached orchestration' >&2; exit 1
fi
# Exercise the actual ECS orchestrator, replacing only external I/O boundaries.
log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT
set_ecs_tf_vars() { :; }
run_tf() { printf '%s\n' 'fixture'; }
plan_apply() { printf '%s %s\n' "$3" "$TF_VAR_honua_image" >> "$log_file"; }
run_ecs_checks() { printf 'serve %s\n' "$TF_VAR_honua_image" >> "$log_file"; }
verify_ecs_canary_route() { :; }
run_honua_platform_post_apply_validation() { :; }
QUICK_SCALE=false
AUTO_DESTROY=true
CHECK_IDEMPOTENCY=false
EXISTING_REDIS_CONNECTION_STRING=fixture
DB_PASSWORD_EFFECTIVE=fixture
apply_ecs_stack >/dev/null
expected="$(printf 'ecs-previous %s\nserve %s\necs-upgrade %s\nserve %s\necs-rollback %s\nserve %s' "$old" "$old" "$new" "$new" "$old" "$old")"
[[ "$(cat "$log_file")" == "$expected" ]] || { cat "$log_file"; exit 1; }
echo 'PASS: digest rejection, distinct revisions, unchanged AOT pins, and N-1 -> N -> N-1 ECS orchestration'
# Docker fallback must receive the same Bedrock configuration as host Terraform.
export TF_VAR_enable_bedrock_ai=true TF_VAR_bedrock_ai_region=us-east-1
USE_DOCKER_TF=true
TEMP_TF_ROOT=/tmp/cert-image-test
# Shell functions shadow external I/O only; the real run_tf constructs the argv.
docker() { printf '%s\n' "$@" > "$log_file"; }
run_tf() { :; } # restore the real helper after the orchestration stubs
source "$TEST_DIR/run-aws-terraform-integration.sh"
USE_DOCKER_TF=true
TEMP_TF_ROOT=/tmp/cert-image-test
run_tf plan
for name in enable_bedrock_ai bedrock_ai_model bedrock_ai_region bedrock_ai_max_tokens bedrock_ai_timeout_seconds; do
  grep -qx "TF_VAR_$name" "$log_file"
done
# ECR returns independently specified digest metadata. Producers must store it,
# never reconstruct the selected mutable tag as the deployment reference.
source "$TEST_DIR/../../../../../scripts/bootstrap-gh-vars.sh"
ECR_REGION=us-east-1
ECR_REPOSITORY=honua-server
fixture_digest="sha256:$(printf 'c%.0s' {1..64})"
aws() {
  if [[ "$1 $2" == 'sts get-caller-identity' ]]; then
    printf '%s\n' 123456789012
  elif [[ "$1 $2" == 'ecr describe-images' ]]; then
    printf '%s\n' "$fixture_digest"
  else
    return 1
  fi
}
resolve_aws_ecs_image
resolve_aws_serverless_image
resolve_aws_eks_image
expected="123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@$fixture_digest"
[[ "$AWS_ECS_IMAGE" == "$expected" && "$AWS_SERVERLESS_IMAGE" == "$expected" && "$EKS_IMAGE" == "$expected" ]]
if ( AWS_ECS_IMAGE=registry.example/honua:latest; resolve_aws_ecs_image ) 2>/dev/null; then
  echo 'Explicit mutable override was accepted by the variable bootstrap' >&2; exit 1
fi
if ( aws() { return 1; }; EKS_IMAGE=''; K8S_IMAGE=registry.example/honua:latest; resolve_aws_eks_image ) 2>/dev/null; then
  echo 'Mutable EKS fallback was accepted by the variable bootstrap' >&2; exit 1
fi
echo 'PASS: Docker Bedrock inputs, ECR digest resolution, and mutable producer rejection'
