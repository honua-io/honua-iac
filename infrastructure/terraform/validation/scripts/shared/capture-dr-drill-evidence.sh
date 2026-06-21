#!/usr/bin/env bash

# Capture structured evidence for a backup/restore or failover drill.
#
# This helper does NOT execute a drill or touch cloud infrastructure on its own.
# It records the measurements an operator collects while running the manual
# runbooks in docs/devops/backup-restore-runbook.md and
# docs/devops/failover-drill-runbook.md, then emits a single JSON evidence
# object plus a pass/fail verdict against the configured RTO/RPO targets.
#
# The output JSON matches docs/devops/dr-evidence-template.json so captured
# evidence can be archived and diffed consistently across runs.

set -euo pipefail

log_info() {
  echo "[INFO] $1" >&2
}

log_warn() {
  echo "[WARN] $1" >&2
}

log_error() {
  echo "[ERROR] $1" >&2
}

usage() {
  cat <<'USAGE'
Capture backup/restore or failover drill evidence as JSON.

Usage:
  capture-dr-drill-evidence.sh [options]

Required:
  --drill <backup-restore|failover>   Drill type being recorded
  --cloud <aws|azure>                 Target cloud
  --target <stack>                    Stack identifier (e.g. aws-ecs, azure-aca,
                                      aws-serverless, azure-functions)

Common:
  --operator <name>                   Operator who ran the drill
  --environment <name>                Environment label (default: validation)
  --db-identifier <id>                RDS identifier / Flexible Server name
  --started-at <iso8601>              Drill start time (default: now, UTC)
  --notes <text>                      Free-form notes / observed failure modes
  --out <path>                        Write JSON to this file (default: stdout)

Backup/restore measurements:
  --restore-seconds <n>               Measured restore duration in seconds
  --restored-table-count <n>          Application tables present after restore
  --postgis-extension-count <n>       PostGIS extensions present after restore
  --backup-method <text>             e.g. pg_dump, RDS snapshot, PITR
  --rto-target-seconds <n>            Pass/fail threshold for restore duration

Failover measurements:
  --rto-seconds <n>                   Measured time to recover service (RTO)
  --rpo-seconds <n>                   Measured/estimated data loss window (RPO)
  --rto-target-seconds <n>            RTO objective to grade against
  --rpo-target-seconds <n>            RPO objective to grade against
  --failover-trigger <text>          e.g. reboot --force-failover, manual promote
  --post-failover-ready <true|false>  Service passed /healthz/ready after failover

Run with no measurement flags to emit a blank template for manual editing.
USAGE
}

DRILL=""
CLOUD=""
TARGET=""
OPERATOR="${HONUA_DR_OPERATOR:-}"
ENVIRONMENT="validation"
DB_IDENTIFIER=""
STARTED_AT=""
NOTES=""
OUT_FILE=""

RESTORE_SECONDS=""
RESTORED_TABLE_COUNT=""
POSTGIS_EXTENSION_COUNT=""
BACKUP_METHOD=""

RTO_SECONDS=""
RPO_SECONDS=""
RTO_TARGET_SECONDS=""
RPO_TARGET_SECONDS=""
FAILOVER_TRIGGER=""
POST_FAILOVER_READY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --drill) DRILL="$2"; shift 2 ;;
    --cloud) CLOUD="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --operator) OPERATOR="$2"; shift 2 ;;
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    --db-identifier) DB_IDENTIFIER="$2"; shift 2 ;;
    --started-at) STARTED_AT="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    --restore-seconds) RESTORE_SECONDS="$2"; shift 2 ;;
    --restored-table-count) RESTORED_TABLE_COUNT="$2"; shift 2 ;;
    --postgis-extension-count) POSTGIS_EXTENSION_COUNT="$2"; shift 2 ;;
    --backup-method) BACKUP_METHOD="$2"; shift 2 ;;
    --rto-seconds) RTO_SECONDS="$2"; shift 2 ;;
    --rpo-seconds) RPO_SECONDS="$2"; shift 2 ;;
    --rto-target-seconds) RTO_TARGET_SECONDS="$2"; shift 2 ;;
    --rpo-target-seconds) RPO_TARGET_SECONDS="$2"; shift 2 ;;
    --failover-trigger) FAILOVER_TRIGGER="$2"; shift 2 ;;
    --post-failover-ready) POST_FAILOVER_READY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "Required command not found: $1"
    exit 1
  fi
}

require_command jq

if [[ -z "$DRILL" || -z "$CLOUD" || -z "$TARGET" ]]; then
  log_error "--drill, --cloud, and --target are required"
  usage
  exit 2
fi

case "$DRILL" in
  backup-restore|failover) ;;
  *) log_error "--drill must be 'backup-restore' or 'failover'"; exit 2 ;;
esac

case "$CLOUD" in
  aws|azure) ;;
  *) log_error "--cloud must be 'aws' or 'azure'"; exit 2 ;;
esac

if [[ -z "$STARTED_AT" ]]; then
  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# num <value> -> JSON number or null
num() {
  if [[ -n "${1:-}" && "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "$1"
  else
    printf 'null'
  fi
}

# str <value> -> jq-escaped JSON string or null
str() {
  if [[ -n "${1:-}" ]]; then
    jq -Rn --arg v "$1" '$v'
  else
    printf 'null'
  fi
}

# bool <value> -> JSON boolean or null
boolean() {
  case "${1:-}" in
    true|True|TRUE|1|yes) printf 'true' ;;
    false|False|FALSE|0|no) printf 'false' ;;
    *) printf 'null' ;;
  esac
}

# Grade a measured value against a target where lower-is-better.
# Returns "pass", "fail", or "not-evaluated".
grade_le() {
  local measured="$1"
  local target="$2"
  if [[ ! "$measured" =~ ^[0-9]+([.][0-9]+)?$ || ! "$target" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf 'not-evaluated'
    return 0
  fi
  if awk "BEGIN { exit !($measured <= $target) }"; then
    printf 'pass'
  else
    printf 'fail'
  fi
}

CHECKS=()

if [[ "$DRILL" == "backup-restore" ]]; then
  table_verdict="not-evaluated"
  if [[ "$RESTORED_TABLE_COUNT" =~ ^[0-9]+$ ]]; then
    if (( RESTORED_TABLE_COUNT > 0 )); then table_verdict="pass"; else table_verdict="fail"; fi
  fi
  postgis_verdict="not-evaluated"
  if [[ "$POSTGIS_EXTENSION_COUNT" =~ ^[0-9]+$ ]]; then
    if (( POSTGIS_EXTENSION_COUNT >= 2 )); then postgis_verdict="pass"; else postgis_verdict="fail"; fi
  fi
  restore_verdict="not-evaluated"
  if [[ -n "$RTO_TARGET_SECONDS" && -n "$RESTORE_SECONDS" ]]; then
    restore_verdict="$(grade_le "$RESTORE_SECONDS" "$RTO_TARGET_SECONDS")"
  fi
  CHECKS+=("$(jq -n --arg n restored_application_tables --arg v "$table_verdict" '{name:$n,verdict:$v}')")
  CHECKS+=("$(jq -n --arg n postgis_extensions_present --arg v "$postgis_verdict" '{name:$n,verdict:$v}')")
  CHECKS+=("$(jq -n --arg n restore_within_rto --arg v "$restore_verdict" '{name:$n,verdict:$v}')")
else
  rto_verdict="not-evaluated"
  if [[ -n "$RTO_TARGET_SECONDS" && -n "$RTO_SECONDS" ]]; then
    rto_verdict="$(grade_le "$RTO_SECONDS" "$RTO_TARGET_SECONDS")"
  fi
  rpo_verdict="not-evaluated"
  if [[ -n "$RPO_TARGET_SECONDS" && -n "$RPO_SECONDS" ]]; then
    rpo_verdict="$(grade_le "$RPO_SECONDS" "$RPO_TARGET_SECONDS")"
  fi
  ready_verdict="not-evaluated"
  case "$POST_FAILOVER_READY" in
    true|True|TRUE|1|yes) ready_verdict="pass" ;;
    false|False|FALSE|0|no) ready_verdict="fail" ;;
  esac
  CHECKS+=("$(jq -n --arg n rto_within_target --arg v "$rto_verdict" '{name:$n,verdict:$v}')")
  CHECKS+=("$(jq -n --arg n rpo_within_target --arg v "$rpo_verdict" '{name:$n,verdict:$v}')")
  CHECKS+=("$(jq -n --arg n service_ready_after_failover --arg v "$ready_verdict" '{name:$n,verdict:$v}')")
fi

checks_json="$(printf '%s\n' "${CHECKS[@]}" | jq -s '.')"

# Overall verdict: fail if any check failed; pass only if at least one check
# was evaluated and none failed; otherwise not-evaluated (blank template).
overall="$(printf '%s' "$checks_json" | jq -r '
  if any(.[]; .verdict == "fail") then "fail"
  elif any(.[]; .verdict == "pass") then "pass"
  else "not-evaluated" end')"

EVIDENCE="$(jq -n \
  --arg schema "honua.dr-drill-evidence/v1" \
  --arg drill "$DRILL" \
  --arg cloud "$CLOUD" \
  --arg target "$TARGET" \
  --arg environment "$ENVIRONMENT" \
  --argjson operator "$(str "$OPERATOR")" \
  --argjson db_identifier "$(str "$DB_IDENTIFIER")" \
  --arg started_at "$STARTED_AT" \
  --arg captured_at "$CAPTURED_AT" \
  --argjson notes "$(str "$NOTES")" \
  --argjson backup_method "$(str "$BACKUP_METHOD")" \
  --argjson restore_seconds "$(num "$RESTORE_SECONDS")" \
  --argjson restored_table_count "$(num "$RESTORED_TABLE_COUNT")" \
  --argjson postgis_extension_count "$(num "$POSTGIS_EXTENSION_COUNT")" \
  --argjson rto_seconds "$(num "$RTO_SECONDS")" \
  --argjson rpo_seconds "$(num "$RPO_SECONDS")" \
  --argjson rto_target_seconds "$(num "$RTO_TARGET_SECONDS")" \
  --argjson rpo_target_seconds "$(num "$RPO_TARGET_SECONDS")" \
  --argjson failover_trigger "$(str "$FAILOVER_TRIGGER")" \
  --argjson post_failover_ready "$(boolean "$POST_FAILOVER_READY")" \
  --argjson checks "$checks_json" \
  --arg verdict "$overall" \
  '{
    schema: $schema,
    drill: $drill,
    cloud: $cloud,
    target: $target,
    environment: $environment,
    operator: $operator,
    db_identifier: $db_identifier,
    started_at: $started_at,
    captured_at: $captured_at,
    measurements: {
      backup_method: $backup_method,
      restore_seconds: $restore_seconds,
      restored_table_count: $restored_table_count,
      postgis_extension_count: $postgis_extension_count,
      rto_seconds: $rto_seconds,
      rpo_seconds: $rpo_seconds,
      failover_trigger: $failover_trigger,
      post_failover_ready: $post_failover_ready
    },
    targets: {
      rto_target_seconds: $rto_target_seconds,
      rpo_target_seconds: $rpo_target_seconds
    },
    checks: $checks,
    verdict: $verdict,
    notes: $notes
  }')"

if [[ -n "$OUT_FILE" ]]; then
  printf '%s\n' "$EVIDENCE" >"$OUT_FILE"
  log_info "Wrote DR drill evidence to $OUT_FILE (verdict: $overall)"
else
  printf '%s\n' "$EVIDENCE"
fi

if [[ "$overall" == "fail" ]]; then
  exit 1
fi
