#!/usr/bin/env bash

# Opt-in secret passes for sweep-orphaned-validation-infra.sh, sourced by it.
#
# CELL-STATE SECRETS (--cell-state-secrets). honua-release e2e/run_cloud.py
# stores each release cell's sealed state, app key and tenant key as UNTAGGED
# secrets named honua-cloud-cell-state/<run id>-<attempt>-<cell>[-suffix], and
# deletes them at teardown. A cancelled or failed cell leaves them behind, and
# the Owner-tag sweep cannot see an untagged resource. This pass reaps one only
# when all of these hold, each a test case in test-sweep-cell-state-secrets.sh:
#
#   * its name is in that namespace and names a GitHub run id;
#   * no protected tag (Environment or Lifecycle standing/cert/demo) is set;
#   * no --protect-run-id names that run;
#   * the run is `completed` and finished longer than --grace-hours ago;
#   * the caller is not --this-run (an owning run tears its own state down).
#
# Deletion keeps a 7-day recovery window (restore-secret undoes it), unlike the
# immediate delete of Owner-tagged cell secrets.
#
# UNTAGGED SECRET REPORT (--report-untagged-secrets). Read-only: lists, in the
# summary, every live secret that carries neither a CloudFormation stack tag nor
# an Owner tag and is not a cell-state secret, so an operator can decide each by
# name. No reaper can prove who owns those.

CELL_STATE_PREFIX="honua-cloud-cell-state/"
CELL_STATE_RECOVERY_DAYS=7
UNTAGGED_SECRET_LINES=()

is_cell_state_secret() { [[ "$(arn_resource "$1")" == "secret:$CELL_STATE_PREFIX"* ]]; }

# True when a protected id names the same GitHub run (gha-<run>-<anything>).
run_is_protected() {
  local gh_run_id="$1" id
  for id in ${PROTECT_RUN_IDS[@]+"${PROTECT_RUN_IDS[@]}"}; do
    [[ "$id" == "gha-$gh_run_id-"* ]] && return 0
  done
  return 1
}

# Emits CAND/SKIP/FAIL records in select_candidates' format.
select_cell_state_secrets() {
  local region="$1" payload arn name gh_run_id state status completed_epoch
  if ! payload="$(aws_read secretsmanager list-secrets --region "$region" \
        --filters "Key=name,Values=$CELL_STATE_PREFIX" --output json 2>/dev/null)" \
      || ! jq -e '.SecretList | type == "array"' >/dev/null 2>&1 <<<"$payload"; then
    emit_fail "could not list cell-state secrets in $region"
    return 0
  fi
  while IFS="$US" read -r arn name; do
    [[ -z "$arn" ]] && continue
    if [[ ! "$name" =~ ^honua-cloud-cell-state/([0-9]+)-[0-9]+-aws-[a-z0-9-]+$ ]]; then
      emit_skip "$arn" "cell-state secret name does not name a GitHub run"
      continue
    fi
    gh_run_id="${BASH_REMATCH[1]}"
    if run_is_protected "$gh_run_id"; then
      emit_skip "$arn" "protected run $gh_run_id"
      continue
    fi
    state="$(run_state "$gh_run_id")"
    status="${state%%|*}"
    completed_epoch="${state#*|}"
    if [[ "$status" != "completed" ]]; then
      emit_skip "$arn" "run $gh_run_id is '$status' (only a completed run is reapable)"
    elif [[ -z "$completed_epoch" ]]; then
      emit_skip "$arn" "run $gh_run_id has no usable completion timestamp"
    elif (( NOW_EPOCH < completed_epoch + GRACE_HOURS * 3600 )); then
      emit_skip "$arn" "run $gh_run_id completed inside the ${GRACE_HOURS}h grace window"
    else
      printf 'CAND%s%s%s%s%s%s\n' "$US" "$arn" "$US" "gha-$gh_run_id-cell-state" "$US" "cell-state"
    fi
  done < <(jq -r --arg p "$CELL_STATE_PREFIX" '
    .SecretList[]
    | select(.DeletedDate == null and (.Name | startswith($p)))
    | select(any((.Tags // [])[]; (.Key == "Environment" and (.Value == "cert" or .Value == "standing" or .Value == "demo")) or (.Key == "Lifecycle" and (.Value == "standing" or .Value == "demo"))) | not)
    | [.ARN, .Name] | join("\u001f")
  ' <<<"$payload")
}

# Dispatches one pass's records into main's candidates (bash locals are
# dynamically scoped, so this appends to the caller's array).
collect_secret_records() {
  local line kind rest
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    kind="${line%%"$US"*}"
    rest="${line#*"$US"}"
    case "$kind" in
      CAND) candidates+=("$1$US$rest") ;;
      SKIP) SKIPPED_LINES+=("${rest%%"$US"*} | ${rest#*"$US"}") ;;
      FAIL) log_warn "$rest"; FAILURES=1 ;;
    esac
  done < <(select_cell_state_secrets "$1")
}

delete_cell_state_secret() {
  aws_write secretsmanager delete-secret --region "$1" --secret-id "$2" \
    --recovery-window-in-days "$CELL_STATE_RECOVERY_DAYS" >/dev/null 2>&1
}

report_untagged_secrets() {
  local region="$1" payload name
  if ! payload="$(aws_read secretsmanager list-secrets --region "$region" --output json 2>/dev/null)" \
      || ! jq -e '.SecretList | type == "array"' >/dev/null 2>&1 <<<"$payload"; then
    log_warn "could not list secrets in $region for the untagged report"
    FAILURES=1
    return 0
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] && UNTAGGED_SECRET_LINES+=("$region | $name")
  done < <(jq -r --arg p "$CELL_STATE_PREFIX" '
    .SecretList[]
    | select(.DeletedDate == null and (.Name | startswith($p) | not))
    | select(any((.Tags // [])[]; .Key == "aws:cloudformation:stack-name" or .Key == "Owner") | not)
    | .Name
  ' <<<"$payload" | sort)
  log_info "Untagged secrets in $region: ${#UNTAGGED_SECRET_LINES[@]} so far (names in the summary)"
}

emit_secret_summary() {
  [[ "$REPORT_UNTAGGED_SECRETS" == "true" ]] || return 0
  echo "#### Unattributed secrets (${#UNTAGGED_SECRET_LINES[@]})"
  echo
  echo "No CloudFormation stack tag and no Owner tag, so no reaper deletes them. Report only."
  echo
  echo '```'
  printf '%s\n' ${UNTAGGED_SECRET_LINES[@]+"${UNTAGGED_SECRET_LINES[@]}"}
  echo '```'
  echo
}
