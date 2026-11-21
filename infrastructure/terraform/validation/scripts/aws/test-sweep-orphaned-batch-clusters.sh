#!/usr/bin/env bash

# Hermetic tests for sweep-orphaned-batch-clusters.sh. AWS Batch creates an ECS
# cluster for each compute environment; one whose compute environment is gone
# is an orphan. The sweep must delete only that, and keep anything a compute
# environment still references, anything with work on it, and anything it
# cannot read. A fake `aws` on PATH logs every call; no network is used.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEPER="$SCRIPT_DIR/sweep-orphaned-batch-clusters.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"

cat > "$TMP_DIR/bin/aws" <<'FAKE_AWS'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$AWS_CALL_LOG"
case "$1 $2" in
  "batch describe-compute-environments")
    [[ -n "${FAKE_CE_ERROR:-}" ]] && { echo "An error occurred ($FAKE_CE_ERROR) when calling the DescribeComputeEnvironments operation: x" >&2; exit 254; }
    echo "$FAKE_CES" ;;
  "ecs list-clusters") echo "$FAKE_CLUSTERS" ;;
  "ecs describe-clusters")
    arn=""; prev=""
    for a in "$@"; do [[ "$prev" == "--clusters" ]] && arn="$a"; prev="$a"; done
    [[ -n "${FAKE_DESCRIBE_ERROR:-}" ]] && { echo "An error occurred ($FAKE_DESCRIBE_ERROR) when calling the DescribeClusters operation: x" >&2; exit 254; }
    jq -c --arg arn "$arn" '{clusters: [.[$arn] // empty], failures: []}' <<<"$FAKE_DETAILS" ;;
  "ecs delete-cluster") exit 0 ;;
  *) echo "unexpected call: $*" >&2; exit 1 ;;
esac
FAKE_AWS
chmod +x "$TMP_DIR/bin/aws"
export PATH="$TMP_DIR/bin:$PATH"
export AWS_CALL_LOG="$TMP_DIR/calls.log"

PASS=0; FAIL=0
check() {
  if [[ "$2" == ok ]]; then echo "  PASS  $1"; PASS=$(( PASS + 1 )); else
    echo "  FAIL  $1"; echo "----- output -----"; echo "$OUT"; echo "----- aws calls -----"; cat "$AWS_CALL_LOG"; FAIL=$(( FAIL + 1 )); fi
}
run() {
  : > "$AWS_CALL_LOG"
  set +e; OUT="$("$SWEEPER" --region us-east-1 "$@" 2>&1)"; RC=$?; set -e
}
deleted() { grep -q "^ecs delete-cluster .*--cluster $1" "$AWS_CALL_LOG"; }

ORPHAN='arn:aws:ecs:us-east-1:1:cluster/AWSBatch-BatchCompute-orphan'
OWNED='arn:aws:ecs:us-east-1:1:cluster/AWSBatch-BatchCompute-live'
OTHER='arn:aws:ecs:us-east-1:1:cluster/honua-it-cluster'
detail() { jq -cn --arg arn "$1" --arg status "${2:-ACTIVE}" --argjson running "${3:-0}" --argjson services "${4:-0}" \
  '{clusterArn:$arn,status:$status,runningTasksCount:$running,pendingTasksCount:0,activeServicesCount:$services,registeredContainerInstancesCount:0}'; }
defaults() {
  export FAKE_CES="$(jq -cn --arg arn "$OWNED" '{computeEnvironments:[{computeEnvironmentName:"BatchCompute-live",ecsClusterArn:$arn}]}')"
  export FAKE_CLUSTERS="$(jq -cn --arg a "$ORPHAN" --arg b "$OWNED" --arg c "$OTHER" '{clusterArns:[$a,$b,$c]}')"
  export FAKE_DETAILS="$(jq -cn --argjson a "$(detail "$ORPHAN")" --argjson b "$(detail "$OWNED")" --argjson c "$(detail "$OTHER")" \
    --arg x "$ORPHAN" --arg y "$OWNED" --arg z "$OTHER" '{($x):$a,($y):$b,($z):$c}')"
  unset FAKE_CE_ERROR FAKE_DESCRIBE_ERROR
}

echo "== an orphaned Batch cluster is deleted; nothing else is =="
defaults; run
if [[ "$RC" -eq 0 ]] && deleted "$ORPHAN"; then check "the orphaned cluster is deleted" ok; else check "the orphaned cluster is deleted" no; fi
if deleted "$OWNED"; then check "a cluster its compute environment references is kept" no; else check "a cluster its compute environment references is kept" ok; fi
if deleted "$OTHER"; then check "a non-Batch cluster is never considered" no; else check "a non-Batch cluster is never considered" ok; fi

echo "== an orphan with work on it is kept and reported =="
defaults
export FAKE_DETAILS="$(jq -c --arg x "$ORPHAN" --argjson d "$(detail "$ORPHAN" ACTIVE 1)" '.[$x]=$d' <<<"$FAKE_DETAILS")"
run
if [[ "$RC" -ne 0 ]] && ! deleted "$ORPHAN" && grep -q "Kept $ORPHAN" <<<"$OUT"; then check "an orphan with running tasks is kept and fails the sweep" ok; else check "an orphan with running tasks is kept and fails the sweep" no; fi
defaults
export FAKE_DETAILS="$(jq -c --arg x "$ORPHAN" --argjson d "$(detail "$ORPHAN" ACTIVE 0 1)" '.[$x]=$d' <<<"$FAKE_DETAILS")"
run
if ! deleted "$ORPHAN"; then check "an orphan with an active service is kept" ok; else check "an orphan with an active service is kept" no; fi

echo "== an already inactive cluster is settled =="
defaults
export FAKE_DETAILS="$(jq -c --arg x "$ORPHAN" --argjson d "$(detail "$ORPHAN" INACTIVE)" '.[$x]=$d' <<<"$FAKE_DETAILS")"
run
if [[ "$RC" -eq 0 ]] && ! deleted "$ORPHAN"; then check "an inactive cluster is not deleted again" ok; else check "an inactive cluster is not deleted again" no; fi

echo "== the sweep refuses when it cannot prove the orphan =="
defaults; export FAKE_CE_ERROR=AccessDeniedException; run
if [[ "$RC" -ne 0 ]] && ! grep -q '^ecs delete-cluster' "$AWS_CALL_LOG"; then check "an unreadable compute-environment list deletes nothing" ok; else check "an unreadable compute-environment list deletes nothing" no; fi
defaults; export FAKE_CES='{"computeEnvironments":[],"nextToken":"more"}'; run
if [[ "$RC" -ne 0 ]] && ! grep -q '^ecs delete-cluster' "$AWS_CALL_LOG"; then check "a truncated compute-environment list deletes nothing" ok; else check "a truncated compute-environment list deletes nothing" no; fi
defaults; export FAKE_CES='{}'; run
if [[ "$RC" -ne 0 ]] && ! grep -q '^ecs delete-cluster' "$AWS_CALL_LOG"; then check "a malformed compute-environment list deletes nothing" ok; else check "a malformed compute-environment list deletes nothing" no; fi
defaults; export FAKE_DESCRIBE_ERROR=ThrottlingException; run
if [[ "$RC" -ne 0 ]] && ! grep -q '^ecs delete-cluster' "$AWS_CALL_LOG"; then check "an unreadable cluster is kept and fails the sweep" ok; else check "an unreadable cluster is kept and fails the sweep" no; fi

echo "== a dry run plans but does not delete =="
defaults; run --dry-run
if [[ "$RC" -eq 0 ]] && ! grep -q '^ecs delete-cluster' "$AWS_CALL_LOG" && grep -q "PLAN delete $ORPHAN" <<<"$OUT"; then check "a dry run plans the orphan without deleting" ok; else check "a dry run plans the orphan without deleting" no; fi

echo
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
