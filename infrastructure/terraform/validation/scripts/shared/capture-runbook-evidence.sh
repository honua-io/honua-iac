#!/usr/bin/env bash

# Capture structured evidence for one manual cloud runbook execution
# (apply -> smoke -> destroy) against a single cloud/runtime/mode cell of the
# deployment validation matrix.
#
# This helper does NOT execute a runbook or touch cloud infrastructure on its
# own. It records the results an operator collects while running the manual
# runbooks in docs/devops/manual-cloud-runbook-validation.md (and the upstream
# honua-devops docs/manual-cloud-runbooks.md), then emits a single JSON
# evidence object plus a pass/fail verdict against the runbook pass criteria.
#
# The output JSON matches docs/devops/cloud-runbook-evidence-template.json so
# captured evidence can be archived and diffed consistently across runs and
# across the matrix.

set -euo pipefail

log_info() {
  echo "[INFO] $1" >&2
}

log_error() {
  echo "[ERROR] $1" >&2
}

usage() {
  cat <<'USAGE'
Capture manual cloud runbook (apply -> smoke -> destroy) evidence as JSON.

Usage:
  capture-runbook-evidence.sh [options]

Required:
  --cloud <aws|azure>                 Target cloud
  --target <stack>                    Stack identifier: aws-ecs, aws-serverless,
                                      azure-aca, azure-functions
  --mode <aot|jit>                    Runtime build mode

Common:
  --launch-class <must-pass|experimental|deferred>
                                      Matrix launch class (default: must-pass)
  --operator <name>                   Operator who ran the runbook
  --environment <name>                Environment label (default: validation)
  --deployment-profile <ephemeral|persistent>
                                      Deployment profile (default: ephemeral)
  --image-ref <ref>                   Image used for the apply
  --honua-url <url>                   Deployed endpoint base URL
  --workflow-run-url <url>            GitHub Actions run URL, if dispatched
  --started-at <iso8601>             Run start time (default: now, UTC)
  --notes <text>                      Free-form notes / observed caveats
  --out <path>                        Write JSON to this file (default: stdout)

Phase results:
  --apply-result <pass|fail|skipped>          terraform apply result
  --apply-seconds <n>                         apply wall-clock seconds
  --smoke-readiness <pass|fail|skipped>       /healthz/ready probe
  --smoke-liveness <pass|fail|skipped>        /healthz/live probe
  --smoke-admin-version <pass|fail|skipped>   admin version probe (API key)
  --admin-ui <pass|fail|not-present|skipped>  admin UI control-plane check
  --destroy-result <pass|fail|skipped>        terraform destroy result
  --destroy-seconds <n>                       destroy wall-clock seconds
  --cleanup-verified <true|false>             post-destroy inventory confirmed empty
  --retained-resources <text>                 any intentionally kept resources

Run with no phase flags to emit a blank template for manual editing.
USAGE
}

CLOUD=""
TARGET=""
MODE=""
LAUNCH_CLASS="must-pass"
OPERATOR="${HONUA_RUNBOOK_OPERATOR:-}"
ENVIRONMENT="validation"
DEPLOYMENT_PROFILE="ephemeral"
IMAGE_REF=""
HONUA_URL=""
WORKFLOW_RUN_URL=""
STARTED_AT=""
NOTES=""
OUT_FILE=""

APPLY_RESULT=""
APPLY_SECONDS=""
SMOKE_READINESS=""
SMOKE_LIVENESS=""
SMOKE_ADMIN_VERSION=""
ADMIN_UI=""
DESTROY_RESULT=""
DESTROY_SECONDS=""
CLEANUP_VERIFIED=""
RETAINED_RESOURCES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloud) CLOUD="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --launch-class) LAUNCH_CLASS="$2"; shift 2 ;;
    --operator) OPERATOR="$2"; shift 2 ;;
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    --deployment-profile) DEPLOYMENT_PROFILE="$2"; shift 2 ;;
    --image-ref) IMAGE_REF="$2"; shift 2 ;;
    --honua-url) HONUA_URL="$2"; shift 2 ;;
    --workflow-run-url) WORKFLOW_RUN_URL="$2"; shift 2 ;;
    --started-at) STARTED_AT="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    --apply-result) APPLY_RESULT="$2"; shift 2 ;;
    --apply-seconds) APPLY_SECONDS="$2"; shift 2 ;;
    --smoke-readiness) SMOKE_READINESS="$2"; shift 2 ;;
    --smoke-liveness) SMOKE_LIVENESS="$2"; shift 2 ;;
    --smoke-admin-version) SMOKE_ADMIN_VERSION="$2"; shift 2 ;;
    --admin-ui) ADMIN_UI="$2"; shift 2 ;;
    --destroy-result) DESTROY_RESULT="$2"; shift 2 ;;
    --destroy-seconds) DESTROY_SECONDS="$2"; shift 2 ;;
    --cleanup-verified) CLEANUP_VERIFIED="$2"; shift 2 ;;
    --retained-resources) RETAINED_RESOURCES="$2"; shift 2 ;;
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

if [[ -z "$CLOUD" || -z "$TARGET" || -z "$MODE" ]]; then
  log_error "--cloud, --target, and --mode are required"
  usage
  exit 2
fi

case "$CLOUD" in
  aws|azure) ;;
  *) log_error "--cloud must be 'aws' or 'azure'"; exit 2 ;;
esac

case "$MODE" in
  aot|jit) ;;
  *) log_error "--mode must be 'aot' or 'jit'"; exit 2 ;;
esac

case "$TARGET" in
  aws-ecs|aws-serverless|azure-aca|azure-functions) ;;
  *) log_error "--target must be one of: aws-ecs, aws-serverless, azure-aca, azure-functions"; exit 2 ;;
esac

case "$LAUNCH_CLASS" in
  must-pass|experimental|deferred) ;;
  *) log_error "--launch-class must be 'must-pass', 'experimental', or 'deferred'"; exit 2 ;;
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

# phase <value> -> normalized phase string or null (for JSON storage)
phase() {
  case "${1:-}" in
    pass|Pass|PASS) printf 'pass' ;;
    fail|Fail|FAIL) printf 'fail' ;;
    skipped|Skipped|SKIPPED) printf 'skipped' ;;
    not-present|not_present) printf 'not-present' ;;
    *) printf '' ;;
  esac
}

# verdict_required <value> -> pass/fail/not-evaluated
# A required phase passes only on explicit "pass"; "fail" -> fail; anything
# else (unset/skipped) -> not-evaluated.
verdict_required() {
  case "$(phase "$1")" in
    pass) printf 'pass' ;;
    fail) printf 'fail' ;;
    *) printf 'not-evaluated' ;;
  esac
}

# verdict_admin_ui -> pass/fail/not-evaluated; "not-present" is acceptable
# because the runbook allows profiles without an admin UI to rely on the
# admin-version probe as the minimum control-plane proof.
verdict_admin_ui() {
  case "$(phase "$1")" in
    pass|not-present) printf 'pass' ;;
    fail) printf 'fail' ;;
    *) printf 'not-evaluated' ;;
  esac
}

# Smoke contract verdict: pass when readiness AND liveness pass; admin-version
# is graded only if it was attempted (pass/fail), not when skipped.
smoke_verdict() {
  local r l a
  r="$(phase "$SMOKE_READINESS")"
  l="$(phase "$SMOKE_LIVENESS")"
  a="$(phase "$SMOKE_ADMIN_VERSION")"
  if [[ "$r" == "fail" || "$l" == "fail" || "$a" == "fail" ]]; then
    printf 'fail'; return 0
  fi
  if [[ "$r" == "pass" && "$l" == "pass" ]]; then
    printf 'pass'; return 0
  fi
  printf 'not-evaluated'
}

cleanup_verdict() {
  case "${CLEANUP_VERIFIED:-}" in
    true|True|TRUE|1|yes) printf 'pass' ;;
    false|False|FALSE|0|no) printf 'fail' ;;
    *) printf 'not-evaluated' ;;
  esac
}

APPLY_VERDICT="$(verdict_required "$APPLY_RESULT")"
SMOKE_CONTRACT_VERDICT="$(smoke_verdict)"
ADMIN_UI_VERDICT="$(verdict_admin_ui "$ADMIN_UI")"
DESTROY_VERDICT="$(verdict_required "$DESTROY_RESULT")"
CLEANUP_VERDICT="$(cleanup_verdict)"

CHECKS=()
CHECKS+=("$(jq -n --arg n apply_succeeded --arg v "$APPLY_VERDICT" '{name:$n,verdict:$v}')")
CHECKS+=("$(jq -n --arg n smoke_contract_passed --arg v "$SMOKE_CONTRACT_VERDICT" '{name:$n,verdict:$v}')")
CHECKS+=("$(jq -n --arg n admin_ui_verified --arg v "$ADMIN_UI_VERDICT" '{name:$n,verdict:$v}')")
CHECKS+=("$(jq -n --arg n destroy_succeeded --arg v "$DESTROY_VERDICT" '{name:$n,verdict:$v}')")
CHECKS+=("$(jq -n --arg n cleanup_verified --arg v "$CLEANUP_VERDICT" '{name:$n,verdict:$v}')")

checks_json="$(printf '%s\n' "${CHECKS[@]}" | jq -s '.')"

# Overall verdict: fail if any check failed; pass only when every check was
# evaluated and none failed; otherwise not-evaluated (incomplete run).
overall="$(printf '%s' "$checks_json" | jq -r '
  if any(.[]; .verdict == "fail") then "fail"
  elif all(.[]; .verdict == "pass") then "pass"
  else "not-evaluated" end')"

# Normalize phase strings for JSON storage (null when unset).
apply_result_json="$(str "$(phase "$APPLY_RESULT")")"
smoke_readiness_json="$(str "$(phase "$SMOKE_READINESS")")"
smoke_liveness_json="$(str "$(phase "$SMOKE_LIVENESS")")"
smoke_admin_version_json="$(str "$(phase "$SMOKE_ADMIN_VERSION")")"
admin_ui_json="$(str "$(phase "$ADMIN_UI")")"
destroy_result_json="$(str "$(phase "$DESTROY_RESULT")")"

EVIDENCE="$(jq -n \
  --arg schema "honua.cloud-runbook-evidence/v1" \
  --arg cloud "$CLOUD" \
  --arg target "$TARGET" \
  --arg mode "$MODE" \
  --arg launch_class "$LAUNCH_CLASS" \
  --arg environment "$ENVIRONMENT" \
  --arg deployment_profile "$DEPLOYMENT_PROFILE" \
  --argjson operator "$(str "$OPERATOR")" \
  --argjson image_ref "$(str "$IMAGE_REF")" \
  --argjson honua_url "$(str "$HONUA_URL")" \
  --argjson workflow_run_url "$(str "$WORKFLOW_RUN_URL")" \
  --arg started_at "$STARTED_AT" \
  --arg captured_at "$CAPTURED_AT" \
  --argjson apply_result "$apply_result_json" \
  --argjson apply_seconds "$(num "$APPLY_SECONDS")" \
  --argjson smoke_readiness "$smoke_readiness_json" \
  --argjson smoke_liveness "$smoke_liveness_json" \
  --argjson smoke_admin_version "$smoke_admin_version_json" \
  --argjson admin_ui "$admin_ui_json" \
  --argjson destroy_result "$destroy_result_json" \
  --argjson destroy_seconds "$(num "$DESTROY_SECONDS")" \
  --argjson cleanup_verified "$(boolean "$CLEANUP_VERIFIED")" \
  --argjson retained_resources "$(str "$RETAINED_RESOURCES")" \
  --argjson checks "$checks_json" \
  --arg verdict "$overall" \
  --argjson notes "$(str "$NOTES")" \
  '{
    schema: $schema,
    cloud: $cloud,
    target: $target,
    mode: $mode,
    launch_class: $launch_class,
    environment: $environment,
    deployment_profile: $deployment_profile,
    operator: $operator,
    image_ref: $image_ref,
    honua_url: $honua_url,
    workflow_run_url: $workflow_run_url,
    started_at: $started_at,
    captured_at: $captured_at,
    phases: {
      apply: {
        result: $apply_result,
        duration_seconds: $apply_seconds
      },
      smoke: {
        readiness: $smoke_readiness,
        liveness: $smoke_liveness,
        admin_version: $smoke_admin_version,
        admin_ui: $admin_ui
      },
      destroy: {
        result: $destroy_result,
        duration_seconds: $destroy_seconds
      },
      cleanup_verified: $cleanup_verified
    },
    retained_resources: $retained_resources,
    checks: $checks,
    verdict: $verdict,
    notes: $notes
  }')"

if [[ -n "$OUT_FILE" ]]; then
  printf '%s\n' "$EVIDENCE" >"$OUT_FILE"
  log_info "Wrote cloud runbook evidence to $OUT_FILE (verdict: $overall)"
else
  printf '%s\n' "$EVIDENCE"
fi

if [[ "$overall" == "fail" ]]; then
  exit 1
fi
