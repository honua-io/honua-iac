#!/usr/bin/env bash

# Reap the AWS infrastructure that terraform-manual-validation leaves behind (#142).
#
# Sibling of sweep-orphaned-validation-iam.sh, which reaps the per-run IAM
# principals (#129). This one reaps the expensive part: the NAT gateways, ALBs,
# RDS instances, ElastiCache groups, ECS clusters and VPCs of a validation cell
# whose run is over.
#
# Three mechanisms strand a cell, and only a tag-driven sweep catches all three:
#
#   1. The run fails mid-apply. run-aws-terraform-integration.sh does install an
#      EXIT trap that destroys, but a destroy that itself errors is only warned
#      about, and terraform then has no more moves.
#   2. The runner is cancelled or lost. No trap on the runner gets to finish, so
#      nothing at all is destroyed.
#   3. The run SUCCEEDS with --keep-data. The shared data stack (VPC + NAT
#      gateway + RDS + ElastiCache) is deliberately retained for reuse by a
#      later run with the same candidate sha, and if that run never comes the
#      stack is retained forever. Two of the 28 leaking runs in #142 concluded
#      `success`, which is why teardown-on-failure alone would not have caught
#      them.
#
# SAFETY. This script deletes live cloud resources, so its refusal rules matter
# more than its deletion rules. Every one of these must hold before anything is
# touched, and each is exercised by test-sweep-orphaned-validation-infra.sh:
#
#   * Candidates come only from the Resource Groups Tagging API filtered on
#     Owner=<owner tag> (default terraform-validation). An untagged resource is
#     invisible to this script by construction — there is no code path that can
#     reach one.
#   * A candidate must carry a ValidationRunId tag of the form gha-<run id>-*.
#     No parseable run id means no proof the resource is disposable: skipped.
#   * That GitHub Actions run must be `completed`. queued/in_progress/waiting,
#     or an id the API will not confirm, means skipped.
#   * The run must have been completed longer than --grace-hours ago, AND the
#     resource's ExpiresAtUTC tag (its TTL, written at apply time) must have
#     elapsed. Both, not either.
#   * If ANY terraform-manual-validation run is currently in progress, the whole
#     sweep defers. A shared data stack carries the ValidationRunId of the run
#     that CREATED it, not of the run currently reusing it, so per-resource run
#     state cannot by itself prove a live run is not depending on it. Deferring
#     a daily sweep costs a day; reaping a live cell costs a release.
#   * --protect-run-id ids are never touched, whatever their state.
#   * --max-delete caps one sweep. A plan larger than the cap is reported and
#     abandoned rather than executed, so a tagging accident cannot cascade.
#   * --dry-run makes the whole thing read-only: it enumerates, prints the exact
#     plan, and issues no mutating API call.
#
# The in-job caller (terraform-manual-validation's always-step) passes
# --this-run with the run ids it owns, which waives the run-state and grace
# checks for exactly those ids and nothing else -- the job knows its own run is
# over because it is the one ending.
#
# TEARDOWN ORDER. Two dependency traps, both learned the hard way:
#
#   * Security groups that reference each other's rules cannot be deleted in any
#     order; AWS returns DependencyViolation until the rules are gone. So every
#     rule on every non-default SG in the VPC is revoked FIRST, then the groups
#     are deleted.
#   * Detached-but-alive ENIs hold their subnet and their security group.
#     honua-release#79 hit this from the other side: the EKS VPC CNI leaves
#     secondary ENIs behind after node-group deletion and terraform destroy then
#     fails on subnet + security group. Its harness sweeps them and retries
#     (e2e/targets/aws_eks.py::_sweep_detached_network_interfaces); this script
#     does the same before touching subnets.

set -euo pipefail

# Field separator for the internal records below. Deliberately NOT a tab: tab is
# an IFS whitespace character, so `IFS=$'\t' read` collapses runs of tabs and
# drops empty fields. A resource with no Stack tag would then have its
# ExpiresAtUTC parsed as its Stack and its expiry check skipped -- a safety
# check quietly not running is the worst possible failure mode here.
US=$'\x1f'

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

usage() {
  cat <<'USAGE'
Usage: sweep-orphaned-validation-infra.sh [options]

Options:
  --region <region>        Region to sweep; repeatable (default: $AWS_REGION /
                           $AWS_DEFAULT_REGION)
  --grace-hours <n>        Hours a run must have been completed before its cell
                           is reapable (default: 4)
  --owner-tag <value>      Owner tag value that marks a resource as ours
                           (default: terraform-validation)
  --repo <owner/name>      Repository whose Actions runs are consulted
                           (default: $GITHUB_REPOSITORY or honua-io/honua-iac)
  --workflow <file>        Workflow file whose in-progress runs defer the sweep
                           (default: terraform-manual-validation.yml)
  --run-id <id>            Restrict the sweep to this ValidationRunId;
                           repeatable
  --this-run               The caller owns the --run-id values: waive the
                           run-completed and grace-window checks for those ids
                           only. Requires at least one --run-id.
  --stack <name>           Only consider resources tagged Stack=<name>;
                           repeatable (data | ecs | serverless)
  --protect-run-id <id>    Never touch resources with this ValidationRunId;
                           repeatable
  --max-delete <n>         Abandon the sweep if the plan exceeds n resources
                           (default: 400)
  --summary-file <path>    Append a markdown report here (job summary)
  --dry-run                Enumerate and print the plan; delete nothing
  --no-defer-on-active     Do not defer when a validation run is in progress.
                           Only safe with --this-run.
  -h, --help               Show this help
USAGE
}

REGIONS=()
GRACE_HOURS=4
OWNER_TAG="terraform-validation"
REPO="${GITHUB_REPOSITORY:-honua-io/honua-iac}"
WORKFLOW_FILE="terraform-manual-validation.yml"
ONLY_RUN_IDS=()
THIS_RUN=false
STACK_FILTERS=()
PROTECT_RUN_IDS=()
MAX_DELETE=400
SUMMARY_FILE=""
DRY_RUN=false
DEFER_ON_ACTIVE=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGIONS+=("$2"); shift 2 ;;
    --grace-hours) GRACE_HOURS="$2"; shift 2 ;;
    --owner-tag) OWNER_TAG="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --workflow) WORKFLOW_FILE="$2"; shift 2 ;;
    --run-id) ONLY_RUN_IDS+=("$2"); shift 2 ;;
    --this-run) THIS_RUN=true; shift ;;
    --stack) STACK_FILTERS+=("$2"); shift 2 ;;
    --protect-run-id) PROTECT_RUN_IDS+=("$2"); shift 2 ;;
    --max-delete) MAX_DELETE="$2"; shift 2 ;;
    --summary-file) SUMMARY_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --no-defer-on-active) DEFER_ON_ACTIVE=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$OWNER_TAG" ]]; then
  log_error "--owner-tag must not be empty; the Owner filter is the only thing standing between this script and the rest of the account"
  exit 1
fi

if ! [[ "$GRACE_HOURS" =~ ^[0-9]+$ ]]; then
  log_error "--grace-hours must be a non-negative integer (got '$GRACE_HOURS')"
  exit 1
fi

if ! [[ "$MAX_DELETE" =~ ^[0-9]+$ ]] || (( MAX_DELETE < 1 )); then
  log_error "--max-delete must be a positive integer (got '$MAX_DELETE')"
  exit 1
fi

if [[ "$THIS_RUN" == "true" && ${#ONLY_RUN_IDS[@]} -eq 0 ]]; then
  log_error "--this-run waives the run-state check and so must name the run ids it waives it for (--run-id)"
  exit 1
fi

for cmd in aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || { log_error "Required command not found: $cmd"; exit 1; }
done

if [[ ${#REGIONS[@]} -eq 0 ]]; then
  default_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  [[ -n "$default_region" ]] && REGIONS+=("$default_region")
fi

if [[ ${#REGIONS[@]} -eq 0 ]]; then
  log_error "No region to sweep: pass --region or set AWS_REGION"
  exit 1
fi

NOW_EPOCH="$(date -u +%s)"
FAILURES=0
PLANNED_ARNS=()
DELETED_ARNS=()
SKIPPED_LINES=()
SURVIVOR_LINES=()
SURVIVOR_ARNS=()
DEFERRED=false

# ---------------------------------------------------------------------------
# plumbing
# ---------------------------------------------------------------------------

epoch_of() { date -u -d "$1" +%s 2>/dev/null || echo ""; }

# Read-only AWS call. Failures are the caller's to interpret.
aws_read() { aws "$@"; }

# Mutating AWS call. Under --dry-run this prints the call and returns success
# without contacting AWS at all, which is what makes the dry run provably
# side-effect free rather than merely intended to be.
aws_write() {
  if [[ "$DRY_RUN" == "true" ]]; then
    # stderr, not stdout: some callers capture a helper's stdout (the VPC
    # security-group list, for one) and a dry-run line on stdout would be parsed
    # as data.
    echo "[dry-run] aws $*" >&2
    return 0
  fi
  aws "$@"
}

contains() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

skip() {
  local arn="$1" reason="$2"
  SKIPPED_LINES+=("$arn | $reason")
}

# select_candidates runs inside a process substitution, i.e. a subshell, so it
# cannot append to the caller's arrays. It emits tagged records instead and the
# caller dispatches them; getting this wrong silently loses every skip reason.
emit_skip() { printf 'SKIP%s%s%s%s\n' "$US" "$1" "$US" "$2"; }
emit_fail() { printf 'FAIL%s%s\n' "$US" "$1"; }

# ---------------------------------------------------------------------------
# GitHub run state
# ---------------------------------------------------------------------------

RUN_STATUS_CACHE_KEYS=()
RUN_STATUS_CACHE_VALUES=()

gh_available() { command -v gh >/dev/null 2>&1; }

# Echoes "<status>|<completed_at epoch or empty>" for a GitHub Actions run id,
# or "unknown|" when the API cannot confirm it. Unknown is treated as
# not-reapable everywhere it is consumed.
run_state() {
  local run_id="$1"
  local i payload status completed epoch

  for i in "${!RUN_STATUS_CACHE_KEYS[@]}"; do
    if [[ "${RUN_STATUS_CACHE_KEYS[$i]}" == "$run_id" ]]; then
      echo "${RUN_STATUS_CACHE_VALUES[$i]}"
      return 0
    fi
  done

  local result="unknown|"
  if gh_available; then
    if payload="$(gh api "repos/$REPO/actions/runs/$run_id" 2>/dev/null)"; then
      status="$(jq -r '.status // "unknown"' <<<"$payload" 2>/dev/null || echo unknown)"
      completed="$(jq -r '.updated_at // ""' <<<"$payload" 2>/dev/null || echo "")"
      epoch=""
      [[ -n "$completed" && "$completed" != "null" ]] && epoch="$(epoch_of "$completed")"
      result="$status|$epoch"
    fi
  fi

  RUN_STATUS_CACHE_KEYS+=("$run_id")
  RUN_STATUS_CACHE_VALUES+=("$result")
  echo "$result"
}

# True when at least one run of the validation workflow is not finished. The
# sweep defers wholesale in that case: a retained data stack is tagged with the
# run that created it, so no per-resource check can prove a currently running
# cell is not reusing it.
validation_runs_active() {
  local payload count state
  gh_available || return 1
  for state in queued in_progress waiting requested pending; do
    if payload="$(gh api "repos/$REPO/actions/workflows/$WORKFLOW_FILE/runs?status=$state&per_page=1" 2>/dev/null)"; then
      count="$(jq -r '.total_count // 0' <<<"$payload" 2>/dev/null || echo 0)"
      [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )) && return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# candidate selection
# ---------------------------------------------------------------------------

# Emits one tagged TSV record per tagged resource:
#   CAND<US><arn><US><run id><US><stack>   reapable
#   SKIP<US><arn><US><reason>              not reapable, with the reason
#   FAIL<US><reason>                       the enumeration itself failed
select_candidates() {
  local region="$1"
  local payload

  if ! payload="$(aws_read resourcegroupstaggingapi get-resources \
        --region "$region" \
        --tag-filters "Key=Owner,Values=$OWNER_TAG" \
        --output json 2>/dev/null)"; then
    emit_fail "could not enumerate tagged resources in $region"
    return 0
  fi

  local line arn run_id stack expires state status completed_epoch cutoff

  while IFS="$US" read -r arn run_id stack expires; do
    [[ -z "$arn" ]] && continue

    if [[ ${#PROTECT_RUN_IDS[@]} -gt 0 ]] && contains "$run_id" "${PROTECT_RUN_IDS[@]}"; then
      emit_skip "$arn" "protected run id $run_id"
      continue
    fi

    if [[ ${#ONLY_RUN_IDS[@]} -gt 0 ]] && ! contains "$run_id" "${ONLY_RUN_IDS[@]}"; then
      emit_skip "$arn" "not in the requested run id set"
      continue
    fi

    if [[ ${#STACK_FILTERS[@]} -gt 0 ]] && ! contains "$stack" "${STACK_FILTERS[@]}"; then
      # A resource with no Stack tag predates the tag, so it cannot be proven to
      # belong to the requested stack. Leave it to the scheduled sweep.
      emit_skip "$arn" "stack '${stack:-<untagged>}' not in the requested stack set"
      continue
    fi

    if [[ ! "$run_id" =~ ^gha-([0-9]+)- ]]; then
      emit_skip "$arn" "ValidationRunId '${run_id:-<missing>}' does not name a GitHub run"
      continue
    fi
    local gh_run_id="${BASH_REMATCH[1]}"

    if [[ "$THIS_RUN" == "true" ]] && contains "$run_id" "${ONLY_RUN_IDS[@]}"; then
      # The caller is the owning run, ending now. Its own cell is reapable
      # without consulting the API or waiting out a grace window.
      printf 'CAND%s%s%s%s%s%s\n' "$US" "$arn" "$US" "$run_id" "$US" "$stack"
      continue
    fi

    state="$(run_state "$gh_run_id")"
    status="${state%%|*}"
    completed_epoch="${state#*|}"

    if [[ "$status" != "completed" ]]; then
      emit_skip "$arn" "run $gh_run_id is '$status' (only a completed run is reapable)"
      continue
    fi

    if [[ -z "$completed_epoch" ]]; then
      emit_skip "$arn" "run $gh_run_id has no usable completion timestamp"
      continue
    fi

    cutoff=$(( completed_epoch + GRACE_HOURS * 3600 ))
    if (( NOW_EPOCH < cutoff )); then
      emit_skip "$arn" "run $gh_run_id completed inside the ${GRACE_HOURS}h grace window"
      continue
    fi

    if [[ -n "$expires" ]]; then
      local expires_epoch
      expires_epoch="$(epoch_of "$expires")"
      if [[ -z "$expires_epoch" ]]; then
        emit_skip "$arn" "ExpiresAtUTC '$expires' is unparseable"
        continue
      fi
      if (( NOW_EPOCH < expires_epoch )); then
        emit_skip "$arn" "ExpiresAtUTC $expires has not elapsed"
        continue
      fi
    fi

    printf 'CAND%s%s%s%s%s%s\n' "$US" "$arn" "$US" "$run_id" "$US" "$stack"
  done < <(jq -r '
    .ResourceTagMappingList[]
    | . as $r
    | ($r.Tags // []) as $tags
    | ($tags | map(select(.Key == "ValidationRunId")) | first | .Value // "") as $run
    | ($tags | map(select(.Key == "Stack")) | first | .Value // "") as $stack
    | ($tags | map(select(.Key == "ExpiresAtUTC")) | first | .Value // "") as $expires
    | [$r.ResourceARN, $run, $stack, $expires] | join("\u001f")
  ' <<<"$payload")
}

# ---------------------------------------------------------------------------
# deletion, in dependency order
# ---------------------------------------------------------------------------

arn_service() { local arn="$1"; awk -F: '{print $3}' <<<"$arn"; }
arn_resource() { local arn="$1"; cut -d: -f6- <<<"$arn"; }

wait_gone() {
  # wait_gone <deadline seconds> <probe command...> -- returns 0 once the probe
  # reports the resource is gone, 1 on timeout.
  local deadline_seconds="$1"; shift
  local deadline=$(( SECONDS + deadline_seconds ))
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  while (( SECONDS < deadline )); do
    if ! "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 15
  done
  return 1
}

delete_ecs() {
  local region="$1" arn="$2" resource
  resource="$(arn_resource "$arn")"
  case "$resource" in
    service/*/*)
      local path="${resource#service/}" cluster name
      cluster="${path%%/*}"; name="${path#*/}"
      aws_write ecs update-service --region "$region" --cluster "$cluster" --service "$name" --desired-count 0 >/dev/null 2>&1 || true
      aws_write ecs delete-service --region "$region" --cluster "$cluster" --service "$name" --force >/dev/null 2>&1 || return 1
      ;;
    cluster/*)
      aws_write ecs delete-cluster --region "$region" --cluster "${resource#cluster/}" >/dev/null 2>&1 || return 1
      ;;
    task-definition/*)
      aws_write ecs deregister-task-definition --region "$region" --task-definition "$arn" >/dev/null 2>&1 || return 1
      ;;
    *) return 1 ;;
  esac
}

delete_elbv2() {
  local region="$1" arn="$2" resource
  resource="$(arn_resource "$arn")"
  case "$resource" in
    loadbalancer/*)
      aws_write elbv2 delete-load-balancer --region "$region" --load-balancer-arn "$arn" >/dev/null 2>&1 || return 1
      # Target groups and the VPC's ENIs stay pinned until the LB is actually gone.
      wait_gone 300 aws elbv2 describe-load-balancers --region "$region" --load-balancer-arns "$arn" || \
        log_warn "Load balancer still present after waiting: $arn"
      ;;
    targetgroup/*)
      aws_write elbv2 delete-target-group --region "$region" --target-group-arn "$arn" >/dev/null 2>&1 || return 1
      ;;
    listener/*)
      aws_write elbv2 delete-listener --region "$region" --listener-arn "$arn" >/dev/null 2>&1 || return 1
      ;;
    *) return 1 ;;
  esac
}

delete_rds() {
  local region="$1" arn="$2" kind name
  kind="$(cut -d: -f6 <<<"$arn")"
  name="$(cut -d: -f7- <<<"$arn")"
  case "$kind" in
    db)
      aws_write rds delete-db-instance --region "$region" --db-instance-identifier "$name" \
        --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1 || return 1
      wait_gone 1800 aws rds describe-db-instances --region "$region" --db-instance-identifier "$name" || \
        log_warn "RDS instance still present after waiting: $name"
      ;;
    subgrp)
      aws_write rds delete-db-subnet-group --region "$region" --db-subnet-group-name "$name" >/dev/null 2>&1 || return 1
      ;;
    pg|og)
      aws_write rds delete-db-parameter-group --region "$region" --db-parameter-group-name "$name" >/dev/null 2>&1 || true
      ;;
    *) return 1 ;;
  esac
}

delete_elasticache() {
  local region="$1" arn="$2" kind name
  kind="$(cut -d: -f6 <<<"$arn")"
  name="$(cut -d: -f7- <<<"$arn")"
  case "$kind" in
    replicationgroup)
      aws_write elasticache delete-replication-group --region "$region" --replication-group-id "$name" \
        --no-retain-primary-cluster >/dev/null 2>&1 || return 1
      wait_gone 1800 aws elasticache describe-replication-groups --region "$region" --replication-group-id "$name" || \
        log_warn "ElastiCache replication group still present after waiting: $name"
      ;;
    cluster)
      aws_write elasticache delete-cache-cluster --region "$region" --cache-cluster-id "$name" >/dev/null 2>&1 || return 1
      ;;
    subnetgroup)
      aws_write elasticache delete-cache-subnet-group --region "$region" --cache-subnet-group-name "$name" >/dev/null 2>&1 || return 1
      ;;
    parametergroup)
      aws_write elasticache delete-cache-parameter-group --region "$region" --cache-parameter-group-name "$name" >/dev/null 2>&1 || true
      ;;
    *) return 1 ;;
  esac
}

delete_simple() {
  local region="$1" arn="$2" service resource
  service="$(arn_service "$arn")"
  resource="$(arn_resource "$arn")"
  case "$service" in
    secretsmanager)
      aws_write secretsmanager delete-secret --region "$region" --secret-id "$arn" \
        --force-delete-without-recovery >/dev/null 2>&1 || return 1
      ;;
    logs)
      local group="${resource#log-group:}"; group="${group%:\*}"
      aws_write logs delete-log-group --region "$region" --log-group-name "$group" >/dev/null 2>&1 || return 1
      ;;
    lambda)
      aws_write lambda delete-function --region "$region" --function-name "$arn" >/dev/null 2>&1 || return 1
      ;;
    kms)
      # Scheduling is the only deletion KMS offers, and 7 days is its floor.
      # Reversible with cancel-key-deletion for the whole window.
      aws_write kms schedule-key-deletion --region "$region" --key-id "$arn" \
        --pending-window-in-days 7 >/dev/null 2>&1 || return 1
      ;;
    sqs|sns|dynamodb|s3|iam)
      # IAM is sweep-orphaned-validation-iam.sh's job; the rest are not created
      # by the validation stacks and are reported rather than guessed at.
      return 2
      ;;
    *) return 2 ;;
  esac
}

# --- EC2 / VPC -------------------------------------------------------------

# Revoke every rule on every non-default security group in the VPC before
# deleting any of them. Cross-referencing groups (the ALB group allows the
# service group and vice versa) cannot be deleted in ANY order while their rules
# stand: AWS answers DependencyViolation and a naive teardown loop stops there.
revoke_vpc_security_group_rules() {
  local region="$1" vpc_id="$2" groups gid payload

  groups="$(aws_read ec2 describe-security-groups --region "$region" \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || echo "")"

  for gid in $groups; do
    [[ -z "$gid" || "$gid" == "None" ]] && continue
    payload="$(aws_read ec2 describe-security-group-rules --region "$region" \
      --filters "Name=group-id,Values=$gid" --output json 2>/dev/null || echo '{}')"

    local ingress egress
    ingress="$(jq -r '[.SecurityGroupRules[]? | select(.IsEgress == false) | .SecurityGroupRuleId] | join(" ")' <<<"$payload")"
    egress="$(jq -r '[.SecurityGroupRules[]? | select(.IsEgress == true) | .SecurityGroupRuleId] | join(" ")' <<<"$payload")"

    if [[ -n "$ingress" ]]; then
      # shellcheck disable=SC2086
      aws_write ec2 revoke-security-group-ingress --region "$region" --group-id "$gid" \
        --security-group-rule-ids $ingress >/dev/null 2>&1 || \
        log_warn "Could not revoke ingress rules on $gid"
    fi
    if [[ -n "$egress" ]]; then
      # shellcheck disable=SC2086
      aws_write ec2 revoke-security-group-egress --region "$region" --group-id "$gid" \
        --security-group-rule-ids $egress >/dev/null 2>&1 || \
        log_warn "Could not revoke egress rules on $gid"
    fi
  done

  echo "$groups"
}

# Delete the ENIs that are detached but alive. A detached ENI still holds its
# subnet and its security group, so subnet and SG deletion fail with
# DependencyViolation until it is gone. Same failure honua-release#79 hit with
# the EKS VPC CNI's secondary ENIs.
sweep_detached_network_interfaces() {
  local region="$1" vpc_id="$2" attempts=0 swept=0
  local payload eni status

  while (( attempts < 8 )); do
    payload="$(aws_read ec2 describe-network-interfaces --region "$region" \
      --filters "Name=vpc-id,Values=$vpc_id" --output json 2>/dev/null || echo '{}')"

    local pending=0
    while IFS="$US" read -r eni status; do
      [[ -z "$eni" ]] && continue
      if [[ "$status" == "available" ]]; then
        if aws_write ec2 delete-network-interface --region "$region" --network-interface-id "$eni" >/dev/null 2>&1; then
          swept=$(( swept + 1 ))
        fi
      else
        pending=$(( pending + 1 ))
      fi
    done < <(jq -r '.NetworkInterfaces[]? | [.NetworkInterfaceId, .Status] | join("\u001f")' <<<"$payload")

    (( pending == 0 )) && break
    [[ "$DRY_RUN" == "true" ]] && break
    attempts=$(( attempts + 1 ))
    sleep 15
  done

  log_info "Swept $swept detached network interface(s) in $vpc_id"
}

delete_vpc() {
  local region="$1" vpc_id="$2" id groups gid

  log_info "Tearing down VPC $vpc_id in $region"

  # NAT gateways first: they are the expensive part, they hold EIPs, and their
  # ENIs block the subnets.
  for id in $(aws_read ec2 describe-nat-gateways --region "$region" \
      --filter "Name=vpc-id,Values=$vpc_id" \
      --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text 2>/dev/null || echo ""); do
    [[ -z "$id" || "$id" == "None" ]] && continue
    aws_write ec2 delete-nat-gateway --region "$region" --nat-gateway-id "$id" >/dev/null 2>&1 || \
      log_warn "Could not delete NAT gateway $id"
  done
  if [[ "$DRY_RUN" != "true" ]]; then
    local deadline=$(( SECONDS + 600 ))
    while (( SECONDS < deadline )); do
      local remaining
      remaining="$(aws_read ec2 describe-nat-gateways --region "$region" \
        --filter "Name=vpc-id,Values=$vpc_id" \
        --query 'length(NatGateways[?State!=`deleted`])' --output text 2>/dev/null || echo 0)"
      [[ "$remaining" == "0" ]] && break
      sleep 15
    done
  fi

  for id in $(aws_read ec2 describe-vpc-endpoints --region "$region" \
      --filters "Name=vpc-id,Values=$vpc_id" \
      --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || echo ""); do
    [[ -z "$id" || "$id" == "None" ]] && continue
    aws_write ec2 delete-vpc-endpoints --region "$region" --vpc-endpoint-ids "$id" >/dev/null 2>&1 || true
  done

  for id in $(aws_read ec2 describe-internet-gateways --region "$region" \
      --filters "Name=attachment.vpc-id,Values=$vpc_id" \
      --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null || echo ""); do
    [[ -z "$id" || "$id" == "None" ]] && continue
    aws_write ec2 detach-internet-gateway --region "$region" --internet-gateway-id "$id" --vpc-id "$vpc_id" >/dev/null 2>&1 || true
    aws_write ec2 delete-internet-gateway --region "$region" --internet-gateway-id "$id" >/dev/null 2>&1 || \
      log_warn "Could not delete internet gateway $id"
  done

  # Rules before groups, ENIs before subnets. Both orderings are load-bearing.
  groups="$(revoke_vpc_security_group_rules "$region" "$vpc_id")"
  sweep_detached_network_interfaces "$region" "$vpc_id"

  for gid in $groups; do
    [[ -z "$gid" || "$gid" == "None" ]] && continue
    aws_write ec2 delete-security-group --region "$region" --group-id "$gid" >/dev/null 2>&1 || \
      log_warn "Could not delete security group $gid"
  done

  for id in $(aws_read ec2 describe-subnets --region "$region" \
      --filters "Name=vpc-id,Values=$vpc_id" \
      --query 'Subnets[].SubnetId' --output text 2>/dev/null || echo ""); do
    [[ -z "$id" || "$id" == "None" ]] && continue
    aws_write ec2 delete-subnet --region "$region" --subnet-id "$id" >/dev/null 2>&1 || \
      log_warn "Could not delete subnet $id"
  done

  # Route tables: the main one goes with the VPC and cannot be deleted first.
  local rt_payload
  rt_payload="$(aws_read ec2 describe-route-tables --region "$region" \
    --filters "Name=vpc-id,Values=$vpc_id" --output json 2>/dev/null || echo '{}')"
  while IFS="$US" read -r rtb assoc_ids is_main; do
    [[ -z "$rtb" ]] && continue
    [[ "$is_main" == "true" ]] && continue
    local assoc
    for assoc in $assoc_ids; do
      [[ -z "$assoc" || "$assoc" == "null" ]] && continue
      aws_write ec2 disassociate-route-table --region "$region" --association-id "$assoc" >/dev/null 2>&1 || true
    done
    aws_write ec2 delete-route-table --region "$region" --route-table-id "$rtb" >/dev/null 2>&1 || \
      log_warn "Could not delete route table $rtb"
  done < <(jq -r '
    .RouteTables[]?
    | [ .RouteTableId,
        ([.Associations[]? | select(.Main != true) | .RouteTableAssociationId] | join(" ")),
        (if ([.Associations[]? | select(.Main == true)] | length) > 0 then "true" else "false" end)
      ] | join("\u001f")' <<<"$rt_payload")

  aws_write ec2 delete-vpc --region "$region" --vpc-id "$vpc_id" >/dev/null 2>&1 || {
    log_warn "Could not delete VPC $vpc_id"
    return 1
  }
}

delete_ec2() {
  local region="$1" arn="$2" resource kind id
  resource="$(arn_resource "$arn")"
  kind="${resource%%/*}"
  id="${resource#*/}"
  case "$kind" in
    vpc) delete_vpc "$region" "$id" || return 1 ;;
    natgateway)
      aws_write ec2 delete-nat-gateway --region "$region" --nat-gateway-id "$id" >/dev/null 2>&1 || return 1
      ;;
    elastic-ip)
      aws_write ec2 release-address --region "$region" --allocation-id "$id" >/dev/null 2>&1 || return 1
      ;;
    network-interface)
      aws_write ec2 delete-network-interface --region "$region" --network-interface-id "$id" >/dev/null 2>&1 || return 1
      ;;
    security-group|subnet|route-table|internet-gateway|vpc-endpoint|dhcp-options)
      # Handled as part of their VPC's teardown; a stray one whose VPC is not
      # ours is reported rather than deleted out of context.
      return 2
      ;;
    *) return 2 ;;
  esac
}

delete_arn() {
  local region="$1" arn="$2" service rc
  service="$(arn_service "$arn")"
  set +e
  case "$service" in
    ecs) delete_ecs "$region" "$arn"; rc=$? ;;
    elasticloadbalancing) delete_elbv2 "$region" "$arn"; rc=$? ;;
    rds) delete_rds "$region" "$arn"; rc=$? ;;
    elasticache) delete_elasticache "$region" "$arn"; rc=$? ;;
    ec2) delete_ec2 "$region" "$arn"; rc=$? ;;
    *) delete_simple "$region" "$arn"; rc=$? ;;
  esac
  set -e
  return "$rc"
}

# Rank an ARN for teardown order. Lower goes first: compute that holds ENIs,
# then load balancers, then data services, then the odds and ends, then the VPC
# itself last because everything above lives inside it.
delete_rank() {
  local arn="$1" service resource
  service="$(arn_service "$arn")"
  resource="$(arn_resource "$arn")"
  case "$service:$resource" in
    ecs:service/*) echo 10 ;;
    ecs:cluster/*) echo 11 ;;
    ecs:task-definition/*) echo 12 ;;
    lambda:*) echo 15 ;;
    elasticloadbalancing:listener/*) echo 20 ;;
    elasticloadbalancing:loadbalancer/*) echo 21 ;;
    elasticloadbalancing:targetgroup/*) echo 22 ;;
    rds:db:*) echo 30 ;;
    rds:subgrp:*) echo 31 ;;
    elasticache:replicationgroup:*) echo 35 ;;
    elasticache:cluster:*) echo 35 ;;
    elasticache:subnetgroup:*) echo 36 ;;
    secretsmanager:*) echo 50 ;;
    logs:*) echo 51 ;;
    kms:*) echo 52 ;;
    ec2:natgateway/*) echo 60 ;;
    ec2:network-interface/*) echo 61 ;;
    ec2:elastic-ip/*) echo 62 ;;
    ec2:vpc/*) echo 90 ;;
    *) echo 70 ;;
  esac
}

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------

emit_summary() {
  local out="${SUMMARY_FILE:-}"
  [[ -z "$out" ]] && return 0

  {
    echo "### Validation cell reaper"
    echo
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "_Dry run — nothing was deleted._"
      echo
    fi
    if [[ "$DEFERRED" == "true" ]]; then
      echo "Deferred: a \`$WORKFLOW_FILE\` run is still in progress, and a retained data stack carries the run id that created it rather than the one reusing it."
      echo
    fi
    echo "| outcome | count |"
    echo "| --- | --- |"
    echo "| planned | ${#PLANNED_ARNS[@]} |"
    echo "| deleted | ${#DELETED_ARNS[@]} |"
    echo "| skipped | ${#SKIPPED_LINES[@]} |"
    echo "| left behind | ${#SURVIVOR_LINES[@]} |"
    echo

    if [[ ${#SURVIVOR_LINES[@]} -gt 0 ]]; then
      echo "#### Left behind"
      echo
      echo "These survived teardown. They are still tagged, so the scheduled reaper will retry, but they are billing until it does."
      echo
      echo '```'
      printf '%s\n' "${SURVIVOR_LINES[@]}"
      echo '```'
      echo
    fi

    if [[ ${#SKIPPED_LINES[@]} -gt 0 ]]; then
      echo "<details><summary>Skipped (${#SKIPPED_LINES[@]})</summary>"
      echo
      echo '```'
      printf '%s\n' "${SKIPPED_LINES[@]}"
      echo '```'
      echo
      echo "</details>"
    fi
  } >> "$out"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  log_info "Sweeping regions: ${REGIONS[*]}"
  log_info "Owner tag: $OWNER_TAG | grace: ${GRACE_HOURS}h | dry-run: $DRY_RUN"

  if [[ "$DEFER_ON_ACTIVE" == "true" && "$THIS_RUN" != "true" ]]; then
    if ! gh_available; then
      log_error "gh is required to prove no validation run is in progress; refusing to sweep blind"
      exit 1
    fi
    if validation_runs_active; then
      DEFERRED=true
      log_warn "A $WORKFLOW_FILE run is in progress; deferring the sweep."
      emit_summary
      exit 0
    fi
  fi

  local region line arn run_id stack rc
  local -a candidates=()

  local kind rest
  for region in "${REGIONS[@]}"; do
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      kind="${line%%"$US"*}"
      rest="${line#*"$US"}"
      case "$kind" in
        CAND) candidates+=("$region$US$rest") ;;
        SKIP) SKIPPED_LINES+=("${rest%%"$US"*} | ${rest#*"$US"}") ;;
        FAIL) log_warn "$rest"; FAILURES=1 ;;
        *) log_warn "Unrecognised candidate record: $line" ;;
      esac
    done < <(select_candidates "$region")
  done

  # Print the refusals as well as the plan. "Why was this NOT reaped" is the
  # question anyone reading this log actually has.
  if [[ ${#SKIPPED_LINES[@]} -gt 0 ]]; then
    log_info "Skipped ${#SKIPPED_LINES[@]} tagged resource(s):"
    printf '  SKIP %s\n' "${SKIPPED_LINES[@]}"
  fi

  if [[ ${#candidates[@]} -eq 0 ]]; then
    log_info "Nothing reapable (${#SKIPPED_LINES[@]} tagged resource(s) skipped)."
    emit_summary
    exit "$FAILURES"
  fi

  # Order the plan, then print it in full before touching anything.
  local -a ordered=()
  while IFS= read -r line; do
    ordered+=("$line")
  done < <(
    for line in "${candidates[@]}"; do
      IFS="$US" read -r region arn run_id stack <<<"$line"
      printf '%s\t%s\n' "$(delete_rank "$arn")" "$line"
    done | sort -n -k1,1 -s | cut -f2-
  )

  for line in "${ordered[@]}"; do
    IFS="$US" read -r region arn run_id stack <<<"$line"
    PLANNED_ARNS+=("$arn")
    echo "PLAN delete $arn (run=$run_id stack=${stack:-<untagged>} region=$region)"
  done

  if (( ${#PLANNED_ARNS[@]} > MAX_DELETE )); then
    log_error "Plan covers ${#PLANNED_ARNS[@]} resources, over the --max-delete cap of $MAX_DELETE. Abandoning: a plan this large is more likely a tagging accident than a leak."
    emit_summary
    exit 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Dry run: ${#PLANNED_ARNS[@]} resource(s) would be deleted; no API call was made."
    emit_summary
    exit "$FAILURES"
  fi

  for line in "${ordered[@]}"; do
    IFS="$US" read -r region arn run_id stack <<<"$line"
    set +e
    delete_arn "$region" "$arn"
    rc=$?
    set -e
    case "$rc" in
      0) DELETED_ARNS+=("$arn"); log_info "Deleted $arn" ;;
      2) skip "$arn" "no deletion path for this resource type; left for its VPC teardown or an operator" ;;
      *) SURVIVOR_ARNS+=("$arn"); SURVIVOR_LINES+=("$arn (run=$run_id)"); FAILURES=1; log_warn "Failed to delete $arn" ;;
    esac
  done

  # Whatever is still tagged after the pass is what was left behind.
  for region in "${REGIONS[@]}"; do
    local remaining
    remaining="$(aws_read resourcegroupstaggingapi get-resources --region "$region" \
      --tag-filters "Key=Owner,Values=$OWNER_TAG" \
      --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || echo "")"
    for arn in $remaining; do
      [[ -z "$arn" || "$arn" == "None" ]] && continue
      if contains "$arn" ${PLANNED_ARNS[@]+"${PLANNED_ARNS[@]}"} && ! contains "$arn" ${DELETED_ARNS[@]+"${DELETED_ARNS[@]}"}; then
        if ! contains "$arn" ${SURVIVOR_ARNS[@]+"${SURVIVOR_ARNS[@]}"}; then
          SURVIVOR_ARNS+=("$arn")
          SURVIVOR_LINES+=("$arn (still tagged after teardown)")
        fi
      fi
    done
  done

  log_info "Deleted ${#DELETED_ARNS[@]} of ${#PLANNED_ARNS[@]} planned resource(s); ${#SURVIVOR_LINES[@]} left behind."
  emit_summary
  exit "$FAILURES"
}

main "$@"
