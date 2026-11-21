#!/usr/bin/env bash

# Teardown is asynchronous: a cluster keeps its stopping tasks for a while after
# its service is deleted, and a NAT gateway keeps its Elastic IP until it has
# finished deleting. A delete refused for that reason is retried after the pass,
# and a NAT gateway's deletion is waited out before its address is released.
# A refusal that is not about ordering (access denied) is not retried.

SWEEP_TEST_HARNESS_ONLY=1
# shellcheck source=test-sweep-orphaned-validation-infra.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-sweep-orphaned-validation-infra.sh"
export SWEEP_RETRY_DELAY_SECONDS=0

CLUSTER_ARN='arn:aws:ecs:us-west-2:1:cluster/honua-it-cluster'
TG_ARN='arn:aws:elasticloadbalancing:us-west-2:1:targetgroup/honua-it-tg/abc'
NAT_ARN='arn:aws:ec2:us-west-2:1:natgateway/nat-0abc'
EIP_ARN='arn:aws:ec2:us-west-2:1:elastic-ip/eipalloc-0abc'
CLUSTER="$(tagged "$CLUSTER_ARN" 'gha-111-aws-ecs' 'ecs' "$PAST")"
TG="$(tagged "$TG_ARN" 'gha-111-aws-ecs' 'ecs' "$PAST")"
NAT="$(tagged "$NAT_ARN" 'gha-111-aws-ecs' 'ecs' "$PAST")"
EIP="$(tagged "$EIP_ARN" 'gha-111-aws-ecs' 'ecs' "$PAST")"

err() { echo "An error occurred ($1) when calling the $2 operation: fixture detail"; }

echo "== deletes refused by teardown ordering are retried =="

FAKE_WRITE_FAIL_ONCE="delete-cluster:$(err ClusterContainsTasksException DeleteCluster);delete-target-group:$(err ResourceInUse DeleteTargetGroup);release-address:$(err AuthFailure ReleaseAddress)" \
  run_sweeper "$(resources "$CLUSTER" "$TG" "$NAT" "$EIP")"
if [[ "$RC" -eq 0 ]]; then check "an ordering refusal that clears on retry does not fail the sweep" ok; else check "an ordering refusal that clears on retry does not fail the sweep" no; fi
assert_deleted "the cluster is deleted on retry" "$CLUSTER_ARN"
assert_deleted "the target group is deleted on retry" "$TG_ARN"
assert_deleted "the Elastic IP is released on retry" "$EIP_ARN"
if [[ "$(grep -c '^ecs delete-cluster ' "$AWS_CALL_LOG")" -eq 2 ]]; then check "the cluster delete is attempted exactly twice" ok; else check "the cluster delete is attempted exactly twice" no; fi
if grep -q '0 left behind' <<<"$OUT"; then check "nothing is reported left behind" ok; else check "nothing is reported left behind" no; fi

echo "== a resource that settles before the retry is not deleted again =="

FAKE_ECS_CLUSTER_STATUS_AFTER_DELETE=INACTIVE \
FAKE_WRITE_FAIL_ONCE="delete-cluster:$(err ClusterContainsTasksException DeleteCluster)" \
  run_sweeper "$(resources "$CLUSTER")"
if [[ "$RC" -eq 0 && "$(grep -c '^ecs delete-cluster ' "$AWS_CALL_LOG")" -eq 1 ]]; then
  check "a resource gone by the retry is settled, not deleted again" ok
else
  check "a resource gone by the retry is settled, not deleted again" no
fi

echo "== a refusal that is not about ordering is not retried =="

FAKE_WRITE_FAILURE="delete-cluster:$(err AccessDeniedException DeleteCluster)" run_sweeper "$(resources "$CLUSTER")"
if [[ "$RC" -ne 0 ]]; then check "access denied still fails the sweep" ok; else check "access denied still fails the sweep" no; fi
if [[ "$(grep -c '^ecs delete-cluster ' "$AWS_CALL_LOG")" -eq 1 ]]; then check "access denied is attempted once" ok; else check "access denied is attempted once" no; fi

echo "== an ordering refusal that persists is still reported =="

FAKE_WRITE_FAILURE="delete-cluster:$(err ClusterContainsTasksException DeleteCluster)" run_sweeper "$(resources "$CLUSTER")"
if [[ "$RC" -ne 0 ]] && grep -q "Failed to delete $CLUSTER_ARN (last service error: ClusterContainsTasksException)" <<<"$OUT"; then
  check "a persistent ordering refusal fails the sweep with its code" ok
else
  check "a persistent ordering refusal fails the sweep with its code" no
fi
if [[ "$(grep -c '^ecs delete-cluster ' "$AWS_CALL_LOG")" -le 4 ]]; then check "retries are bounded" ok; else check "retries are bounded" no; fi

echo "== a NAT gateway's deletion is waited out before its address is released =="

run_sweeper "$(resources "$NAT" "$EIP")"
nat_line="$(grep -n '^ec2 delete-nat-gateway ' "$AWS_CALL_LOG" | head -1 | cut -d: -f1 || true)"
wait_line="$(grep -n '^ec2 describe-nat-gateways .*--nat-gateway-ids nat-0abc' "$AWS_CALL_LOG" | head -1 | cut -d: -f1 || true)"
release_line="$(grep -n '^ec2 release-address ' "$AWS_CALL_LOG" | head -1 | cut -d: -f1 || true)"
if [[ -n "$nat_line" && -n "$wait_line" && -n "$release_line" ]] && (( nat_line < wait_line && wait_line < release_line )); then
  check "the NAT gateway state is polled between its delete and the address release" ok
else
  check "the NAT gateway state is polled between its delete and the address release" no
fi

echo
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
