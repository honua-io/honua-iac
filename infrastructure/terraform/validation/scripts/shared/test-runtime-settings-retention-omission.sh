#!/usr/bin/env bash
set -euo pipefail

# A shared mocked Terraform state must reject a changed document when the
# previous hash/document was omitted from the Git-owned retention map.
log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

if terraform -chdir=infrastructure/terraform/modules/aws-serverless test -json \
  -test-directory=tests-retention-negative \
  -filter=tests-retention-negative/omitted_history.tftest.hcl >"$log_file" 2>&1; then
  printf '%s\n' 'Expected runtime settings history omission to fail, but Terraform succeeded.' >&2
  exit 1
fi

python3 - "$log_file" <<'PY'
import json
import sys

events = []
with open(sys.argv[1], encoding="utf-8") as stream:
    for line in stream:
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            raise SystemExit("Terraform emitted non-JSON output during the mocked retention test")

def completed_run(name, status):
    return any(
        event.get("type") == "test_run"
        and event.get("test_run", {}).get("run") == name
        and event.get("test_run", {}).get("progress") == "complete"
        and event.get("test_run", {}).get("status") == status
        for event in events
    )

failure = "changed_settings_without_history_must_refuse_plan"
diagnostics = [
    event for event in events
    if event.get("type") == "diagnostic" and event.get("@testrun") == failure
]
expected_diagnostic = any(
    "Instance cannot be destroyed" in event.get("diagnostic", {}).get("summary", "")
    and "prevent_destroy" in event.get("diagnostic", {}).get("detail", "")
    and any(
        name in event.get("diagnostic", {}).get("detail", "")
        for name in ("aws_secretsmanager_secret.runtime_settings", "aws_secretsmanager_secret_version.runtime_settings")
    )
    for event in diagnostics
)
if not (
    completed_run("initial_published_settings", "pass")
    and completed_run(failure, "fail")
    and expected_diagnostic
):
    summaries = [event.get("diagnostic", {}).get("summary", "") for event in events if event.get("type") == "diagnostic"]
    raise SystemExit(f"Unexpected mocked retention result; diagnostic summaries: {summaries[:6]}")
PY

printf '%s\n' 'Terraform shared-state plan refused to remove an immutable runtime settings secret (prevent_destroy).'
