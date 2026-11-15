#!/usr/bin/env bash

# A delete the service refuses fails the sweep and says why. Only the service's
# error code is repeated: the message can name other resources.

SWEEP_TEST_HARNESS_ONLY=1
# shellcheck source=test-sweep-orphaned-validation-infra.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-sweep-orphaned-validation-infra.sh"

REAPABLE="$(tagged 'arn:aws:ecs:us-west-2:1:cluster/honua-it-cluster' 'gha-111-aws-ecs' 'ecs' "$PAST")"
KEY="$(tagged 'arn:aws:kms:us-west-2:1:key/abc' 'gha-111-aws-ecs' 'ecs' "$PAST")"
SUMMARY="$TMP_DIR/summary.md"

echo "== a refused delete is reported with the service's error code =="

DENIED='An error occurred (AccessDeniedException) when calling the DeleteCluster operation: fixture detail arn:aws:iam::1:role/other'
: > "$SUMMARY"
FAKE_WRITE_FAILURE="delete-cluster:$DENIED" run_sweeper "$(resources "$REAPABLE" "$KEY")" --summary-file "$SUMMARY"
if [[ "$RC" -ne 0 ]] && grep -q 'Failed to delete arn:aws:ecs:us-west-2:1:cluster/honua-it-cluster (last service error: AccessDeniedException)' <<<"$OUT"; then
  check "a refused delete fails the sweep and names the service error" ok
else
  check "a refused delete fails the sweep and names the service error" no
fi
if grep -q 'cluster/honua-it-cluster (run=gha-111-aws-ecs; last service error AccessDeniedException)' "$SUMMARY"; then
  check "the summary lists the refused delete with its error" ok
else
  check "the summary lists the refused delete with its error" no
fi
if grep -q 'fixture detail' <<<"$OUT" || grep -q 'fixture detail' "$SUMMARY"; then
  check "the service's error message is not repeated" no
else
  check "the service's error message is not repeated" ok
fi
assert_deleted "a later resource is still reaped after a refused delete" 'arn:aws:kms:us-west-2:1:key/abc'
if grep -q 'Deleted arn:aws:kms:us-west-2:1:key/abc (' <<<"$OUT"; then
  check "an earlier error is not attached to a later success" no
else
  check "an earlier error is not attached to a later success" ok
fi

NO_WRITE="$(tagged 'arn:aws:ecs:us-west-2:1:capacity-provider/honua-it' 'gha-111-aws-ecs' 'ecs' "$PAST")"
FAKE_WRITE_FAILURE="delete-cluster:$DENIED" run_sweeper "$(resources "$NO_WRITE" "$REAPABLE")"
if grep -q 'Failed to delete arn:aws:ecs:us-west-2:1:capacity-provider/honua-it$' <<<"$OUT"; then
  check "an earlier error is not attached to a later failure that made no call" ok
else
  check "an earlier error is not attached to a later failure that made no call" no
fi

FAKE_WRITE_FAILURE='delete-cluster:connection reset' run_sweeper "$(resources "$REAPABLE")"
if [[ "$RC" -ne 0 ]] && grep -q 'Failed to delete arn:aws:ecs:us-west-2:1:cluster/honua-it-cluster$' <<<"$OUT"; then
  check "a failure without a service error code invents no reason" ok
else
  check "a failure without a service error code invents no reason" no
fi

FAKE_WRITE_FAILURE="update-service:$DENIED" run_sweeper "$(resources "$(tagged 'arn:aws:ecs:us-west-2:1:service/honua-it-cluster/web' 'gha-111-aws-ecs' 'ecs' "$PAST")")"
if [[ "$RC" -eq 0 ]] && ! grep -q 'AccessDeniedException' <<<"$OUT"; then
  check "a tolerated failure inside a successful teardown is not reported" ok
else
  check "a tolerated failure inside a successful teardown is not reported" no
fi

echo
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
