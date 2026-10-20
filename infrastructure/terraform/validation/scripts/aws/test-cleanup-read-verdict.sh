#!/usr/bin/env bash
# Hermetic read-only response controls; no AWS binary, credentials or network.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/cleanup-read-verdict.sh"
PASS=0
check() {
  local expected="$1" name="$2" actual=0; shift 2
  "$@" >/dev/null 2>&1 || actual=$?
  if [[ "$actual" != "$expected" ]]; then echo "FAIL: $name expected=$expected actual=$actual"; exit 1; fi
  PASS=$((PASS+1))
}
# Finite fake provider: only the five read operations/tag enumeration accepted.
fake_read() {
  case "$1 $2" in
    'kms describe-key'|'secretsmanager describe-secret'|'ecs describe-clusters'|'ecs describe-services'|'ecs describe-task-definition')
      if [[ -n "${ERROR:-}" ]]; then printf '%s\n' "$ERROR" >&2; return 1; fi
      printf '%s\n' "$PAYLOAD" ;;
    'resourcegroupstaggingapi get-resources')
      if [[ -n "${TAG_ERROR:-}" ]]; then return 1; fi
      printf '%s\n' "$TAG_PAYLOAD" ;;
    *) echo 'unexpected command' >&2; return 99 ;;
  esac
}
region=us-west-2
ERROR=''; TAG_ERROR=''
for pair in 'kms:key/test' 'secretsmanager:secret:test' 'ecs:cluster/test' 'ecs:service/test/name' 'ecs:task-definition/test:1'; do
  arn="arn:aws:${pair%%:*}:$region:123456789012:${pair#*:}"
  for error in AccessDeniedException ThrottlingException 'connection reset'; do
    ERROR="$error" check 3 "$pair error $error unverified" cleanup_resource_settled fake_read "$region" "$arn"
  done
  for payload in '' '{}' 'null' '[]' '{bad' '{"failures":[],"clusters":[],"services":[]}'; do
    PAYLOAD="$payload" check 3 "$pair malformed unverified" cleanup_resource_settled fake_read "$region" "$arn"
  done
  case "$pair" in
    kms:*) PAYLOAD="$(jq -cn --arg arn "$arn" '{KeyMetadata:{Arn:$arn,KeyState:"PendingDeletion"}}')" ;;
    secretsmanager:*) PAYLOAD="$(jq -cn --arg arn "$arn" '{ARN:$arn,DeletedDate:"2026-10-20T12:00:00+00:00"}')" ;;
    ecs:cluster*) PAYLOAD="$(jq -cn --arg arn "$arn" '{clusters:[{clusterArn:$arn,status:"INACTIVE"}],failures:[]}')" ;;
    ecs:service*) PAYLOAD="$(jq -cn --arg arn "$arn" '{services:[{serviceArn:$arn,status:"INACTIVE"}],failures:[]}')" ;;
    ecs:task*) PAYLOAD="$(jq -cn --arg arn "$arn" '{taskDefinition:{taskDefinitionArn:$arn,status:"INACTIVE"}}')" ;;
  esac
  check 0 "$pair settled positive" cleanup_resource_settled fake_read "$region" "$arn"
  PAYLOAD="${PAYLOAD//123456789012/999999999999}" check 3 "$pair wrong identity" cleanup_resource_settled fake_read "$region" "$arn"
done
key=arn:aws:kms:$region:123456789012:key/test
secret=arn:aws:secretsmanager:$region:123456789012:secret:test
ERROR='An error occurred (NotFoundException) when calling the DescribeKey operation: absent' check 0 'typed KMS absence' cleanup_resource_settled fake_read "$region" "$key"
ERROR='An error occurred (ResourceNotFoundException) when calling the DescribeSecret operation: absent' check 0 'typed secret absence' cleanup_resource_settled fake_read "$region" "$secret"
# Actual AWS CLI errorhandler formatting: leading/trailing newline around ClientError.
ERROR=$'\nAn error occurred (NotFoundException) when calling the DescribeKey operation: absent\n' check 0 'CLI formatted KMS absence' cleanup_resource_settled fake_read "$region" "$key"
ERROR=$' \n\tAn error occurred (ResourceNotFoundException) when calling the DescribeSecret operation: absent\r\n ' check 0 'whitespace formatted secret absence' cleanup_resource_settled fake_read "$region" "$secret"
ERROR=$'warning\nAn error occurred (ResourceNotFoundException) when calling the DescribeSecret operation: absent' check 3 'warning is not whitespace framing' cleanup_resource_settled fake_read "$region" "$secret"
ERROR='AccessDenied: ResourceNotFoundException' check 3 'notfound text is not typed absence' cleanup_resource_settled fake_read "$region" "$secret"
for kind in cluster service; do
  arn="arn:aws:ecs:$region:123456789012:$kind/test"; [[ "$kind" == service ]] && arn+='/name'
  field=clusters; identity=clusterArn; [[ "$kind" == service ]] && { field=services; identity=serviceArn; }
  PAYLOAD="$(jq -cn --arg arn "$arn" --arg f "$field" '{($f):[],failures:[{arn:$arn,reason:"MISSING"}]}')"
  check 0 "$kind exact MISSING" cleanup_resource_settled fake_read "$region" "$arn"
  for mutation in '.failures[0].arn="foreign"' '.failures[0].reason="ACCESS_DENIED"' '.failures={}' '.failures=[]' '.failures += .failures' '.failures=[null]'; do
    PAYLOAD="$(jq "$mutation" <<<"$PAYLOAD")" check 3 "$kind malformed/mismatched failures" cleanup_resource_settled fake_read "$region" "$arn"
  done
  for state in ACTIVE DRAINING; do
    PAYLOAD="$(jq -cn --arg arn "$arn" --arg f "$field" --arg i "$identity" --arg s "$state" '{($f):[{($i):$arn,status:$s}],failures:[]}')"
    check 1 "$kind $state live" cleanup_resource_settled fake_read "$region" "$arn"
  done
done
PAYLOAD="$(jq -cn --arg arn "$secret" '{ARN:$arn}')" check 1 'undeleted secret live' cleanup_resource_settled fake_read "$region" "$secret"
PAYLOAD="$(jq -cn --arg arn "$key" '{KeyMetadata:{Arn:$arn,KeyState:"Enabled"}}')" check 1 'enabled key live' cleanup_resource_settled fake_read "$region" "$key"
for payload in '' '{}' 'null' '{"ResourceTagMappingList":null}' '{"ResourceTagMappingList":[null]}' '{"ResourceTagMappingList":[{"ResourceARN":false}]}' '{"ResourceTagMappingList":[],"PaginationToken":"more"}'; do
  TAG_PAYLOAD="$payload" check 3 'malformed/incomplete tag enumeration' cleanup_tagged_arns fake_read
 done
for tags in 'null' '{}' '"bad"' '[null]' '[{"Key":false,"Value":"v"}]' '[{"Key":"k","Value":false}]' '[{"Key":"k","Value":"v"},{"Key":"k","Value":"v2"}]'; do
  TAG_PAYLOAD="$(jq -cn --arg arn "$secret" --argjson tags "$tags" '{ResourceTagMappingList:[{ResourceARN:$arn,Tags:$tags}]}')" check 3 'malformed or ambiguous optional Tags' cleanup_tagged_arns fake_read
done
TAG_PAYLOAD='{"ResourceTagMappingList":[]}'
check 0 'authoritative empty tags' cleanup_tagged_arns fake_read
TAG_ERROR=denied check 3 'failed tag read' cleanup_tagged_arns fake_read
# Actual integration consumer, sourced through its existing non-executing seam.
source "$SCRIPT_DIR/run-aws-terraform-integration.sh"
run_aws() { fake_read "$@"; }
sleep() { :; } # No wall-clock waits in hermetic live-resource refusal controls.
REGION="$region"; VALIDATION_RUN_ID=gha-test
TAG_PAYLOAD='{"ResourceTagMappingList":[]}'
check 0 'integration authoritative empty' verify_no_leaks
TAG_ERROR=denied check 1 'integration enumeration error refused' verify_no_leaks
TAG_PAYLOAD='{}' check 1 'integration malformed enumeration refused' verify_no_leaks
TAG_PAYLOAD="$(jq -cn --arg arn "$secret" '{ResourceTagMappingList:[{ResourceARN:$arn}]}')"
ERROR=AccessDenied check 1 'integration provider error refused' verify_no_leaks
PAYLOAD="$(jq -cn --arg arn "$secret" '{ARN:$arn,DeletedDate:12345}')" check 0 'integration known settled' verify_no_leaks
PAYLOAD="$(jq -cn --arg arn "$secret" '{ARN:$arn}')" check 1 'integration live never passes' verify_no_leaks
printf 'cleanup read verdict controls passed: %s\n' "$PASS"
