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
# Finite fake provider: only the supported read operations/tag enumeration accepted.
fake_read() {
  case "$1 $2" in
    'ec2 describe-addresses'|'kms describe-key'|'secretsmanager describe-secret'|'ecs describe-clusters'|'ecs describe-services'|'ecs describe-task-definition'|'batch describe-job-definitions'|'acm describe-certificate'|'s3api get-bucket-location')
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
address=arn:aws:ec2:$region:123456789012:elastic-ip/eipalloc-0123456789abcdef0
PAYLOAD='{"Addresses":[]}' check 0 'absent address settled' cleanup_resource_settled fake_read "$region" "$address"
PAYLOAD='{"Addresses":[{"AllocationId":"eipalloc-0123456789abcdef0"}]}' check 1 'allocated address live' cleanup_resource_settled fake_read "$region" "$address"
ERROR='An error occurred (InvalidAllocationID.NotFound) when calling the DescribeAddresses operation: absent' check 0 'typed address absence' cleanup_resource_settled fake_read "$region" "$address"
for error in AuthFailure UnauthorizedOperation Throttling 'connection reset'; do
  ERROR="An error occurred ($error) when calling the DescribeAddresses operation: refused" check 3 "address $error unverified" cleanup_resource_settled fake_read "$region" "$address"
done
for payload in '{}' 'null' '{"Addresses":null}' '{"Addresses":[null]}' '{"Addresses":[{"AllocationId":"eipalloc-foreign"}]}' '{"Addresses":[],"NextToken":"more"}'; do
  PAYLOAD="$payload" check 3 'malformed/mismatched address response' cleanup_resource_settled fake_read "$region" "$address"
done
jobdef=arn:aws:batch:$region:123456789012:job-definition/honuartest-it-gp-s:1
PAYLOAD='{"jobDefinitions":[]}' check 0 'unknown job definition settled' cleanup_resource_settled fake_read "$region" "$jobdef"
PAYLOAD="$(jq -cn --arg arn "$jobdef" '{jobDefinitions:[{jobDefinitionArn:$arn,status:"INACTIVE"}]}')" check 0 'deregistered job definition settled' cleanup_resource_settled fake_read "$region" "$jobdef"
PAYLOAD="$(jq -cn --arg arn "$jobdef" '{jobDefinitions:[{jobDefinitionArn:$arn,status:"ACTIVE"}]}')" check 1 'active job definition live' cleanup_resource_settled fake_read "$region" "$jobdef"
for payload in '{}' 'null' '{"jobDefinitions":null}' '{"jobDefinitions":[{"jobDefinitionArn":"foreign","status":"INACTIVE"}]}' '{"jobDefinitions":[],"nextToken":"more"}' "$(jq -cn --arg arn "$jobdef" '{jobDefinitions:[{jobDefinitionArn:$arn,status:"GONE"}]}')"; do
  PAYLOAD="$payload" check 3 'malformed/mismatched job definition response' cleanup_resource_settled fake_read "$region" "$jobdef"
done
ERROR=AccessDeniedException check 3 'job definition read denied' cleanup_resource_settled fake_read "$region" "$jobdef"
cert=arn:aws:acm:$region:123456789012:certificate/0123abcd
PAYLOAD="$(jq -cn --arg arn "$cert" '{Certificate:{CertificateArn:$arn,Status:"ISSUED"}}')" check 1 'described certificate live' cleanup_resource_settled fake_read "$region" "$cert"
ERROR='An error occurred (ResourceNotFoundException) when calling the DescribeCertificate operation: absent' check 0 'typed certificate absence' cleanup_resource_settled fake_read "$region" "$cert"
ERROR='An error occurred (AccessDeniedException) when calling the DescribeCertificate operation: refused' check 3 'certificate read denied' cleanup_resource_settled fake_read "$region" "$cert"
PAYLOAD='{"Certificate":{"CertificateArn":"foreign"}}' check 3 'foreign certificate refused' cleanup_resource_settled fake_read "$region" "$cert"
bucket=arn:aws:s3:::honuartest-it-alb-logs-cf0d63a0
PAYLOAD='{"LocationConstraint":null}' check 1 'us-east-1 bucket live' cleanup_resource_settled fake_read "$region" "$bucket"
PAYLOAD='{"LocationConstraint":"us-west-2"}' check 1 'regional bucket live' cleanup_resource_settled fake_read "$region" "$bucket"
ERROR='An error occurred (NoSuchBucket) when calling the GetBucketLocation operation: absent' check 0 'typed bucket absence' cleanup_resource_settled fake_read "$region" "$bucket"
ERROR='An error occurred (AccessDenied) when calling the GetBucketLocation operation: refused' check 3 'bucket read denied' cleanup_resource_settled fake_read "$region" "$bucket"
for payload in '{}' 'null' '{"LocationConstraint":5}'; do
  PAYLOAD="$payload" check 3 'malformed bucket location' cleanup_resource_settled fake_read "$region" "$bucket"
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
