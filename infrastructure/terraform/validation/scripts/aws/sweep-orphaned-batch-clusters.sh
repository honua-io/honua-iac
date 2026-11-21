#!/usr/bin/env bash

# Delete ECS clusters that AWS Batch created for a compute environment that no
# longer exists. Batch names them AWSBatch-<compute
# environment>[-<suffix>] and gives them no Owner tag, so the tag-driven sweep
# never sees them; when the stack around a compute environment is torn down
# the cluster can be left behind.
#
# A cluster is deleted only when ALL hold:
#   * its name starts with AWSBatch-;
#   * the complete, unpaginated compute-environment list for the region (any
#     state) does not reference its ARN;
#   * it is ACTIVE with no running or pending tasks, no active services and no
#     registered container instances.
# Any read that fails or is malformed keeps the cluster and fails the sweep.
#
# usage: sweep-orphaned-batch-clusters.sh --region <r> [--region <r>...]
#          [--dry-run] [--summary-file <path>]

set -euo pipefail

REGIONS=()
DRY_RUN=false
SUMMARY_FILE=""
FAILURES=0
DELETED=()
KEPT=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGIONS+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --summary-file) SUMMARY_FILE="$2"; shift 2 ;;
    *) echo "[ERROR] unknown argument: $1" >&2; exit 2 ;;
  esac
done
(( ${#REGIONS[@]} > 0 )) || { echo "[ERROR] at least one --region is required" >&2; exit 2; }

keep() { KEPT+=("$1 ($2)"); FAILURES=1; echo "[WARN] Kept $1: $2" >&2; }

referenced_clusters() {
  local region="$1" payload
  payload="$(aws batch describe-compute-environments --region "$region" --output json)" || return 1
  jq -er 'if type=="object" and (.computeEnvironments|type)=="array" and ((has("nextToken")|not) or .nextToken==null or .nextToken=="")
          then [.computeEnvironments[] | .ecsClusterArn // empty] | join("\n") else error("unverified") end' <<<"$payload"
}

batch_clusters() {
  local region="$1" payload
  payload="$(aws ecs list-clusters --region "$region" --output json)" || return 1
  jq -er 'if type=="object" and (.clusterArns|type)=="array" and ((has("nextToken")|not) or .nextToken==null or .nextToken=="")
          then [.clusterArns[] | select(test(":cluster/AWSBatch-"))] | join("\n") else error("unverified") end' <<<"$payload"
}

# Prints idle, settled or busy; fails when the cluster cannot be read.
cluster_state() {
  local region="$1" arn="$2" payload
  payload="$(aws ecs describe-clusters --region "$region" --clusters "$arn" --output json)" || return 1
  jq -er --arg arn "$arn" '
    if (.clusters|type)!="array" or (.clusters|length)!=1 or .clusters[0].clusterArn!=$arn then error("unverified")
    else .clusters[0] as $c |
      if $c.status=="INACTIVE" then "settled"
      elif $c.status=="ACTIVE" and $c.runningTasksCount==0 and $c.pendingTasksCount==0
           and $c.activeServicesCount==0 and $c.registeredContainerInstancesCount==0 then "idle"
      else "busy" end
    end' <<<"$payload"
}

sweep_region() {
  local region="$1" referenced clusters arn state
  if ! referenced="$(referenced_clusters "$region")"; then
    keep "region $region" "compute environments could not be listed completely"; return
  fi
  if ! clusters="$(batch_clusters "$region")"; then
    keep "region $region" "ECS clusters could not be listed completely"; return
  fi
  while IFS= read -r arn; do
    [[ -z "$arn" ]] && continue
    if grep -Fxq -- "$arn" <<<"$referenced"; then continue; fi
    if ! state="$(cluster_state "$region" "$arn")"; then keep "$arn" "state could not be read"; continue; fi
    case "$state" in
      settled) echo "[INFO] Already inactive: $arn" ;;
      busy) keep "$arn" "no compute environment references it, but it still has tasks, services or instances" ;;
      idle)
        echo "PLAN delete $arn (no compute environment references it; idle)"
        [[ "$DRY_RUN" == "true" ]] && continue
        if aws ecs delete-cluster --region "$region" --cluster "$arn" >/dev/null; then
          DELETED+=("$arn"); echo "[INFO] Deleted $arn"
        else
          keep "$arn" "delete refused"
        fi
        ;;
    esac
  done <<<"$clusters"
}

for region in "${REGIONS[@]}"; do sweep_region "$region"; done

echo "[INFO] Orphaned Batch clusters: ${#DELETED[@]} deleted, ${#KEPT[@]} kept."
if [[ -n "$SUMMARY_FILE" ]]; then
  {
    echo "### Orphaned AWS Batch clusters"
    echo "Deleted ${#DELETED[@]}, kept ${#KEPT[@]} (dry run: $DRY_RUN)."
    (( ${#DELETED[@]} == 0 )) || printf -- '- deleted %s\n' "${DELETED[@]}"
    (( ${#KEPT[@]} == 0 )) || printf -- '- kept %s\n' "${KEPT[@]}"
  } >> "$SUMMARY_FILE"
fi
exit "$FAILURES"
