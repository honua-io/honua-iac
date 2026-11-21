#!/usr/bin/env bash
# Delete-and-retry helpers for sweep-orphaned-validation-infra.sh, which sources
# this file. They use the sweep's globals (PLAN results, US, aws_read/aws_write,
# delete_arn, already_settled, skip, log_*).

nat_gateway_present() {
  local state
  state="$(aws_read ec2 describe-nat-gateways --region "$1" --nat-gateway-ids "$2" \
    --query 'NatGateways[0].State' --output text 2>/dev/null)" || return 1
  # A failed gateway never reaches "deleted" and holds no address worth waiting for.
  [[ -n "$state" && "$state" != "None" && "$state" != "deleted" && "$state" != "failed" ]]
}

# A delete refused only because a dependent teardown is still finishing: a
# cluster's tasks are stopping, a target group's load balancer or a member
# cluster's replication group is deleting, a NAT gateway still holds its
# address. These are retried after the pass; any other refusal is final.
ordering_refusal() {
  local arn="$1" code="$2"
  case "$code" in
    ClusterContainsTasksException|ClusterContainsServicesException|ResourceInUse|ResourceInUseException|\
    InvalidCacheClusterState|InvalidReplicationGroupState|DependencyViolation|InvalidDBInstanceState|\
    InvalidDBSubnetGroupStateFault|InvalidCacheSubnetGroupInUse|CacheSubnetGroupInUse) return 0 ;;
    AuthFailure) [[ "$arn" == arn:aws:ec2:*:elastic-ip/* ]] ;;
    *) return 1 ;;
  esac
}

# The service's authoritative "already gone" answer to a delete. Only a retry
# trusts it: the resource was planned live, refused for ordering, and has since
# been removed by its parent (a replication group takes its member clusters).
gone_on_retry() {
  case "$1" in
    CacheClusterNotFound|CacheClusterNotFoundFault|ReplicationGroupNotFoundFault|DBInstanceNotFound|DBInstanceNotFoundFault|\
    DBSubnetGroupNotFoundFault|CacheSubnetGroupNotFoundFault|ClusterNotFoundException|TargetGroupNotFound|LoadBalancerNotFound|\
    InvalidAllocationID.NotFound|InvalidVpcID.NotFound|InvalidNatGatewayID.NotFound) return 0 ;;
    *) return 1 ;;
  esac
}

# attempt_delete <plan line> <may defer> [retrying]: delete one planned resource
# and record the outcome. With <may defer> true an ordering refusal is queued in
# RETRY_LINES instead of being reported as left behind.
attempt_delete() {
  local line="$1" may_defer="$2" retrying="${3:-false}" region arn run_id stack rc
  IFS="$US" read -r region arn run_id stack <<<"$line"
  LAST_WRITE_ERROR=""
  set +e
  delete_arn "$region" "$arn"
  rc=$?
  set -e
  case "$rc" in
    0) DELETED_ARNS+=("$arn"); log_info "Deleted $arn" ;;
    2) skip "$arn" "no deletion path for this resource type; left for its VPC teardown or an operator" ;;
    *)
      if [[ "$retrying" == "true" ]] && gone_on_retry "$LAST_WRITE_ERROR"; then
        SETTLED_ARNS+=("$arn")
        log_info "Settled before retry: $arn"
        return 0
      fi
      if [[ "$may_defer" == "true" ]] && ordering_refusal "$arn" "$LAST_WRITE_ERROR"; then
        RETRY_LINES+=("$line")
        log_info "Delete of $arn refused while a dependent teardown finishes ($LAST_WRITE_ERROR); will retry"
        return 0
      fi
      SURVIVOR_ARNS+=("$arn")
      SURVIVOR_LINES+=("$arn (run=$run_id${LAST_WRITE_ERROR:+; last service error $LAST_WRITE_ERROR})")
      FAILURES=1
      log_warn "Failed to delete $arn${LAST_WRITE_ERROR:+ (last service error: $LAST_WRITE_ERROR)}"
      ;;
  esac
}

# Retry ordering refusals, in rank order, for a bounded number of rounds. A
# resource that settled meanwhile (its replication group took it, say) is
# credited as settled rather than deleted again.
retry_ordering_refusals() {
  local rounds="${SWEEP_RETRY_ROUNDS:-3}" delay="${SWEEP_RETRY_DELAY_SECONDS:-60}" round line settled may_defer
  local region arn run_id stack
  local -a pending
  [[ "$rounds" =~ ^[0-9]+$ ]] && (( rounds >= 1 )) || rounds=1
  for (( round = 1; round <= rounds && ${#RETRY_LINES[@]} > 0; round++ )); do
    pending=("${RETRY_LINES[@]}")
    RETRY_LINES=()
    log_info "Retry round $round of $rounds for ${#pending[@]} resource(s) after ${delay}s"
    sleep "$delay"
    for line in "${pending[@]}"; do
      IFS="$US" read -r region arn run_id stack <<<"$line"
      set +e
      already_settled "$region" "$arn"
      settled=$?
      set -e
      if (( settled == 0 )); then
        SETTLED_ARNS+=("$arn")
        log_info "Settled before retry: $arn"
        continue
      fi
      may_defer="false"; (( round < rounds )) && may_defer="true"
      attempt_delete "$line" "$may_defer" true
    done
  done
}
