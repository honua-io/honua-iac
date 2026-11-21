#!/usr/bin/env bash

# Opt-in secret passes for sweep-orphaned-validation-infra.sh, sourced by it.
#
# CELL-STATE SECRETS (--cell-state-secrets). honua-release e2e/run_cloud.py
# stores each release cell's sealed state, app key and tenant key as UNTAGGED
# secrets named honua-cloud-cell-state/<run id>-<attempt>-<cell>[-suffix]. The
# Owner-tag sweep cannot see an untagged resource.
#
# Only the -app-key and -tenant-signing-key secrets are reapable: teardown
# deletes them unconditionally and only their own run reads them. The base key
# and its -retirement-<run>-<attempt> copies are KEPT ON PURPOSE when a cell is
# not destroyed: they hold the cell's sealed Terraform state, which
# cloud-cell-retirement.yml needs at any later date. Deleting one can strand a
# live cell, so this pass never plans them and the report lists them instead.
#
# A key secret is reaped only when all of these hold, each a test case in
# test-sweep-cell-state-secrets.sh:
#
#   * its name is <prefix><run id>-<attempt>-aws-<cell>-(app-key|tenant-signing-key);
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
# an Owner tag and is not a cell-state secret, and separately the retained cell
# Terraform state keys, so an operator can decide each by name.

CELL_STATE_PREFIX="honua-cloud-cell-state/"
CELL_STATE_RECOVERY_DAYS=7
CELL_KEY_SUFFIX='-(app-key|tenant-signing-key)'
UNTAGGED_SECRET_LINES=()
RETAINED_STATE_LINES=()
SECRETS_LISTED=false

is_cell_state_secret() { [[ "$(arn_resource "$1")" == "secret:$CELL_STATE_PREFIX"* ]]; }
is_cell_key_name() { [[ "$1" =~ ^honua-cloud-cell-state/[0-9]+-[0-9]+-aws-[a-z0-9-]+$CELL_KEY_SUFFIX$ && "$1" != *-retirement-* ]]; }

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
    if ! is_cell_key_name "$name"; then
      emit_skip "$arn" "sealed cell Terraform state; kept until its cell is retired (report only)"
      continue
    fi
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
  SECRETS_LISTED=true
  while IFS= read -r name; do
    [[ -n "$name" ]] && UNTAGGED_SECRET_LINES+=("$region | $name")
  done < <(jq -r --arg p "$CELL_STATE_PREFIX" '
    .SecretList[]
    | select(.DeletedDate == null and (.Name | startswith($p) | not))
    | select(any((.Tags // [])[]; .Key == "aws:cloudformation:stack-name" or .Key == "Owner") | not)
    | .Name
  ' <<<"$payload" | sort)
  while IFS= read -r name; do
    [[ -n "$name" ]] && ! is_cell_key_name "$name" && RETAINED_STATE_LINES+=("$region | $name")
  done < <(jq -r --arg p "$CELL_STATE_PREFIX" '.SecretList[] | select(.DeletedDate == null and (.Name | startswith($p))) | .Name' <<<"$payload" | sort)
  log_info "Untagged secrets in $region: ${#UNTAGGED_SECRET_LINES[@]} so far (names in the summary)"
}

emit_secret_summary() {
  [[ "$REPORT_UNTAGGED_SECRETS" == "true" ]] || return 0
  if [[ "$SECRETS_LISTED" != "true" ]]; then
    echo "#### Unattributed secrets: not checked (the sweep deferred or the listing failed)"
    echo
    return 0
  fi
  echo "#### Unattributed secrets (${#UNTAGGED_SECRET_LINES[@]})"
  echo
  echo "No CloudFormation stack tag and no Owner tag, so no reaper deletes them. Report only."
  echo
  echo '```'
  printf '%s\n' ${UNTAGGED_SECRET_LINES[@]+"${UNTAGGED_SECRET_LINES[@]}"}
  echo '```'
  echo
  echo "#### Retained cell state (${#RETAINED_STATE_LINES[@]})"
  echo
  echo "Sealed Terraform state of cells that were not destroyed. Retire the cell (honua-release cloud-cell-retirement.yml) before deleting one."
  echo
  echo '```'
  printf '%s\n' ${RETAINED_STATE_LINES[@]+"${RETAINED_STATE_LINES[@]}"}
  echo '```'
  echo
}
