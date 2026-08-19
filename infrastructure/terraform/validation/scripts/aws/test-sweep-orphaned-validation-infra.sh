#!/usr/bin/env bash

# Hermetic tests for sweep-orphaned-validation-infra.sh.
#
# The reaper deletes live cloud resources, so what has to be proven is not that
# it deletes — it is that it REFUSES to. Every test below is a refusal case
# except the two that assert the happy path and the teardown ordering.
#
# No AWS or GitHub credentials are used and no network call is made: fake `aws`
# and `gh` binaries are put on PATH ahead of the real ones. The fake `aws`
# appends every invocation to a log, so a test can assert both what was called
# and — more importantly — that nothing mutating was called at all.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEPER="$SCRIPT_DIR/sweep-orphaned-validation-infra.sh"

if [[ ! -x "$SWEEPER" ]]; then
  echo "[ERROR] sweeper not executable: $SWEEPER" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

# Verbs that change the world. If one of these shows up in the call log when a
# test expected a refusal, the reaper is not safe.
MUTATING='delete-|revoke-|release-|detach-|deregister-|update-service|schedule-key-deletion|delete_'

cat > "$FAKE_BIN/aws" <<'FAKE_AWS'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$AWS_CALL_LOG"

args=("$@")
service="${args[0]:-}"
operation="${args[1]:-}"

value_of() {
  local flag="$1" i
  for (( i = 0; i < ${#args[@]}; i++ )); do
    if [[ "${args[$i]}" == "$flag" ]]; then
      echo "${args[$((i+1))]:-}"
      return 0
    fi
  done
  echo ""
}

has_flag() {
  local flag="$1" a
  for a in "${args[@]}"; do [[ "$a" == "$flag" ]] && return 0; done
  return 1
}

case "$service $operation" in
  "resourcegroupstaggingapi get-resources")
    # The Owner tag filter is the reaper's containment boundary. Anything not
    # matching it is simply not returned, exactly as the real API behaves.
    filter="$(value_of --tag-filters)"
    if [[ "$filter" != "Key=Owner,Values=terraform-validation" ]]; then
      echo '{"ResourceTagMappingList":[]}'
      exit 0
    fi
    payload="$(cat "$FIXTURE_RESOURCES")"
    if has_flag --query; then
      # Survivor re-query: text list of ARNs.
      jq -r '[.ResourceTagMappingList[].ResourceARN] | join("\t")' <<<"$payload"
    else
      echo "$payload"
    fi
    ;;
  "ec2 describe-security-groups")
    echo "${FAKE_SG_IDS:-}"
    ;;
  "ec2 describe-security-group-rules")
    gid="$(value_of --filters)"
    echo '{"SecurityGroupRules":[{"SecurityGroupRuleId":"sgr-in","IsEgress":false},{"SecurityGroupRuleId":"sgr-out","IsEgress":true}]}'
    ;;
  "ec2 describe-network-interfaces")
    echo "${FAKE_ENIS:-{\"NetworkInterfaces\":[]}}"
    ;;
  "ec2 describe-nat-gateways")
    if has_flag --query; then echo "0"; else echo '{"NatGateways":[]}'; fi
    ;;
  "ec2 describe-subnets")
    echo "${FAKE_SUBNET_IDS:-}"
    ;;
  "ec2 describe-route-tables")
    echo '{"RouteTables":[]}'
    ;;
  "ec2 describe-vpc-endpoints"|"ec2 describe-internet-gateways")
    echo ""
    ;;
  *describe-*|*list-*)
    # Anything still describable is reported as already gone, so wait_gone
    # returns immediately.
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
FAKE_AWS

cat > "$FAKE_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -uo pipefail
path="${2:-}"
case "$path" in
  *"/actions/workflows/"*"/runs?status="*)
    echo "{\"total_count\": ${FAKE_ACTIVE_RUNS:-0}}"
    ;;
  *"/actions/runs/"*)
    run_id="${path##*/}"
    file="$FAKE_GH_RUNS/$run_id.json"
    if [[ -f "$file" ]]; then cat "$file"; else exit 1; fi
    ;;
  *)
    exit 1
    ;;
esac
FAKE_GH

chmod +x "$FAKE_BIN/aws" "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH"

FAKE_GH_RUNS="$TMP_DIR/runs"
mkdir -p "$FAKE_GH_RUNS"
export FAKE_GH_RUNS

now_epoch="$(date -u +%s)"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

LONG_AGO="$(iso $(( now_epoch - 72 * 3600 )))"
JUST_NOW="$(iso $(( now_epoch - 60 )))"
FUTURE="$(iso $(( now_epoch + 24 * 3600 )))"
PAST="$(iso $(( now_epoch - 24 * 3600 )))"

# Run 111: completed three days ago -> reapable.
cat > "$FAKE_GH_RUNS/111.json" <<EOF
{"status":"completed","conclusion":"failure","updated_at":"$LONG_AGO"}
EOF
# Run 222: still running -> never reapable, whatever its tags say.
cat > "$FAKE_GH_RUNS/222.json" <<EOF
{"status":"in_progress","conclusion":null,"updated_at":"$JUST_NOW"}
EOF
# Run 333: completed a minute ago -> inside the grace window.
cat > "$FAKE_GH_RUNS/333.json" <<EOF
{"status":"completed","conclusion":"success","updated_at":"$JUST_NOW"}
EOF
# Run 444 is deliberately absent: an id the API will not confirm.

fixture() {
  # fixture <name> <json>
  local file="$TMP_DIR/$1.json"
  printf '%s\n' "$2" > "$file"
  echo "$file"
}

tagged() {
  # tagged <arn> <run id> <stack> <expires>
  local arn="$1" run="$2" stack="$3" expires="$4"
  jq -n --arg arn "$arn" --arg run "$run" --arg stack "$stack" --arg exp "$expires" '
    {ResourceARN: $arn, Tags: (
      [{Key:"Owner", Value:"terraform-validation"}]
      + (if $run   != "" then [{Key:"ValidationRunId", Value:$run}]  else [] end)
      + (if $stack != "" then [{Key:"Stack", Value:$stack}]          else [] end)
      + (if $exp   != "" then [{Key:"ExpiresAtUTC", Value:$exp}]     else [] end)
    )}'
}

resources() {
  jq -n --slurpfile items <(printf '%s\n' "$@") '{ResourceTagMappingList: $items}'
}

PASS=0
FAIL=0

run_sweeper() {
  # run_sweeper <fixture json> <args...> ; sets OUT / RC / AWS_CALL_LOG
  local fixture_json="$1"; shift
  export FIXTURE_RESOURCES="$TMP_DIR/resources.json"
  printf '%s\n' "$fixture_json" > "$FIXTURE_RESOURCES"
  export AWS_CALL_LOG="$TMP_DIR/aws-calls.log"
  : > "$AWS_CALL_LOG"
  set +e
  OUT="$("$SWEEPER" --region us-west-2 --repo honua-io/honua-iac "$@" 2>&1)"
  RC=$?
  set -e
}

check() {
  local name="$1" condition="$2"
  if [[ "$condition" == "ok" ]]; then
    echo "  PASS  $name"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL  $name"
    echo "----- output -----"
    echo "$OUT"
    echo "----- aws calls -----"
    cat "$AWS_CALL_LOG"
    echo "---------------------"
    FAIL=$(( FAIL + 1 ))
  fi
}

assert_no_mutations() {
  local name="$1"
  if grep -Eq "$MUTATING" "$AWS_CALL_LOG"; then
    check "$name" "no"
  else
    check "$name" "ok"
  fi
}

assert_deleted() {
  local name="$1" arn="$2"
  if grep -q "Deleted $arn" <<<"$OUT"; then check "$name" ok; else check "$name" no; fi
}

assert_not_planned() {
  local name="$1" arn="$2"
  if grep -q "PLAN delete $arn" <<<"$OUT"; then check "$name" no; else check "$name" ok; fi
}

echo "== the reaper refuses when it cannot prove a resource is dead =="

REAPABLE="$(tagged 'arn:aws:ecs:us-west-2:1:cluster/honua-it-cluster' 'gha-111-aws-ecs' 'ecs' "$PAST")"

# 1. A resource whose run is still in progress is never touched.
LIVE="$(tagged 'arn:aws:ecs:us-west-2:1:cluster/live-cluster' 'gha-222-aws-ecs' 'ecs' "$PAST")"
run_sweeper "$(resources "$LIVE")"
assert_not_planned "run in progress is not planned" 'arn:aws:ecs:us-west-2:1:cluster/live-cluster'
assert_no_mutations "run in progress triggers no mutating call"

# 2. A resource with no ValidationRunId cannot be attributed, so it is left.
UNATTRIBUTED="$(tagged 'arn:aws:rds:us-west-2:1:db:mystery' '' '' "$PAST")"
run_sweeper "$(resources "$UNATTRIBUTED")"
assert_not_planned "resource without a ValidationRunId is not planned" 'arn:aws:rds:us-west-2:1:db:mystery'
assert_no_mutations "resource without a ValidationRunId triggers no mutating call"

# 3. A run id the GitHub API will not confirm is treated as unknown, not as dead.
UNKNOWN="$(tagged 'arn:aws:rds:us-west-2:1:db:unknown-run' 'gha-444-aws-ecs' 'ecs' "$PAST")"
run_sweeper "$(resources "$UNKNOWN")"
assert_not_planned "unconfirmable run id is not planned" 'arn:aws:rds:us-west-2:1:db:unknown-run'
assert_no_mutations "unconfirmable run id triggers no mutating call"

# 4. A completed run inside the grace window is not yet reapable.
FRESH="$(tagged 'arn:aws:rds:us-west-2:1:db:fresh' 'gha-333-aws-ecs' 'ecs' "$PAST")"
run_sweeper "$(resources "$FRESH")"
assert_not_planned "completed inside the grace window is not planned" 'arn:aws:rds:us-west-2:1:db:fresh'
assert_no_mutations "completed inside the grace window triggers no mutating call"

# 5. An unelapsed ExpiresAtUTC vetoes a reap even when the run is long over.
UNEXPIRED="$(tagged 'arn:aws:rds:us-west-2:1:db:unexpired' 'gha-111-aws-ecs' 'data' "$FUTURE")"
run_sweeper "$(resources "$UNEXPIRED")"
assert_not_planned "unelapsed ExpiresAtUTC is not planned" 'arn:aws:rds:us-west-2:1:db:unexpired'
assert_no_mutations "unelapsed ExpiresAtUTC triggers no mutating call"

# 6. --protect-run-id wins over everything.
run_sweeper "$(resources "$REAPABLE")" --protect-run-id gha-111-aws-ecs
assert_not_planned "protected run id is not planned" 'arn:aws:ecs:us-west-2:1:cluster/honua-it-cluster'
assert_no_mutations "protected run id triggers no mutating call"

# 7. A live validation run defers the whole sweep, even for an otherwise
#    reapable cell — a retained data stack carries its creator's run id.
FAKE_ACTIVE_RUNS=1 run_sweeper "$(resources "$REAPABLE")"
if grep -q "deferring the sweep" <<<"$OUT"; then check "active validation run defers the sweep" ok; else check "active validation run defers the sweep" no; fi
assert_no_mutations "deferred sweep triggers no mutating call"

# 8. --dry-run is provably read-only.
run_sweeper "$(resources "$REAPABLE")" --dry-run
if grep -q "PLAN delete arn:aws:ecs:us-west-2:1:cluster/honua-it-cluster" <<<"$OUT"; then
  check "dry run still prints the plan" ok
else
  check "dry run still prints the plan" no
fi
assert_no_mutations "dry run triggers no mutating call"

# 9. Owner is the containment boundary: a differently-owned account resource is
#    never even enumerated.
run_sweeper "$(resources "$REAPABLE")" --owner-tag some-other-owner
assert_not_planned "a non-validation owner enumerates nothing" 'arn:aws:ecs:us-west-2:1:cluster/honua-it-cluster'
assert_no_mutations "a non-validation owner triggers no mutating call"

# 10. --max-delete abandons an implausibly large plan rather than executing it.
many=()
for i in $(seq 1 5); do
  many+=("$(tagged "arn:aws:ecs:us-west-2:1:cluster/bulk-$i" 'gha-111-aws-ecs' 'ecs' "$PAST")")
done
run_sweeper "$(resources "${many[@]}")" --max-delete 3
if grep -q "over the --max-delete cap" <<<"$OUT"; then check "oversized plan is abandoned" ok; else check "oversized plan is abandoned" no; fi
assert_no_mutations "abandoned oversized plan triggers no mutating call"
if [[ "$RC" -ne 0 ]]; then check "abandoned oversized plan exits nonzero" ok; else check "abandoned oversized plan exits nonzero" no; fi

# 11. --stack skips resources that cannot be proven to belong to that stack.
DATA="$(tagged 'arn:aws:rds:us-west-2:1:db:shared-data' 'gha-111-aws-ecs' 'data' "$PAST")"
run_sweeper "$(resources "$DATA" "$REAPABLE")" --stack ecs --stack serverless
assert_not_planned "a data-stack resource is skipped under --stack ecs" 'arn:aws:rds:us-west-2:1:db:shared-data'

# 12. --this-run must name the runs whose checks it waives.
run_sweeper "$(resources "$REAPABLE")" --this-run
if [[ "$RC" -ne 0 ]] && grep -q "must name the run ids" <<<"$OUT"; then
  check "--this-run without --run-id is refused" ok
else
  check "--this-run without --run-id is refused" no
fi

echo "== the reaper does reap what it can prove is dead =="

# 13. The happy path: run long completed, TTL elapsed, no live run.
run_sweeper "$(resources "$REAPABLE")"
assert_deleted "an expired cell from a completed run is deleted" 'arn:aws:ecs:us-west-2:1:cluster/honua-it-cluster'

# 14. --this-run reaps its own cell without consulting the API or the grace
#     window, but only for the ids it names.
OTHER="$(tagged 'arn:aws:ecs:us-west-2:1:cluster/other-cell' 'gha-333-aws-ecs' 'ecs' "$FUTURE")"
MINE="$(tagged 'arn:aws:ecs:us-west-2:1:cluster/my-cell' 'gha-999-aws-ecs' 'ecs' "$FUTURE")"
run_sweeper "$(resources "$MINE" "$OTHER")" --this-run --run-id gha-999-aws-ecs --no-defer-on-active
assert_deleted "--this-run reaps its own cell" 'arn:aws:ecs:us-west-2:1:cluster/my-cell'
assert_not_planned "--this-run does not reap another run's cell" 'arn:aws:ecs:us-west-2:1:cluster/other-cell'

echo "== teardown order =="

# 15. Security group rules are revoked before the groups are deleted, and
#     detached ENIs are swept before subnets. Both orderings are what make VPC
#     teardown terminate instead of stalling on DependencyViolation.
VPC="$(tagged 'arn:aws:ec2:us-west-2:1:vpc/vpc-abc' 'gha-111-aws-ecs' 'data' "$PAST")"
export FAKE_SG_IDS="sg-1	sg-2"
export FAKE_SUBNET_IDS="subnet-1"
export FAKE_ENIS='{"NetworkInterfaces":[{"NetworkInterfaceId":"eni-1","Status":"available"}]}'
run_sweeper "$(resources "$VPC")"
unset FAKE_SG_IDS FAKE_SUBNET_IDS FAKE_ENIS

order_of() { grep -n -- "$1" "$AWS_CALL_LOG" | head -1 | cut -d: -f1; }
revoke_line="$(order_of 'revoke-security-group-ingress')"
delete_sg_line="$(order_of 'delete-security-group')"
eni_line="$(order_of 'delete-network-interface')"
subnet_line="$(order_of 'delete-subnet')"
vpc_line="$(order_of 'delete-vpc')"

if [[ -n "$revoke_line" && -n "$delete_sg_line" ]] && (( revoke_line < delete_sg_line )); then
  check "security group rules are revoked before the groups are deleted" ok
else
  check "security group rules are revoked before the groups are deleted" no
fi
if [[ -n "$eni_line" && -n "$subnet_line" ]] && (( eni_line < subnet_line )); then
  check "detached ENIs are swept before subnets are deleted" ok
else
  check "detached ENIs are swept before subnets are deleted" no
fi
if [[ -n "$vpc_line" && -n "$subnet_line" ]] && (( subnet_line < vpc_line )); then
  check "the VPC is deleted last" ok
else
  check "the VPC is deleted last" no
fi

# 16. A summary file records what was left behind.
SUMMARY="$TMP_DIR/summary.md"
: > "$SUMMARY"
run_sweeper "$(resources "$REAPABLE")" --summary-file "$SUMMARY"
if grep -q "Validation cell reaper" "$SUMMARY"; then check "a job summary is emitted" ok; else check "a job summary is emitted" no; fi

echo
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
