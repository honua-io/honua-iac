#!/usr/bin/env bash

# honua-release stores each cell's sealed state as an UNTAGGED secret named
# honua-cloud-cell-state/<run>-<attempt>-<cell>[-suffix]. A cancelled or failed
# cell leaves it behind, and the Owner-tag sweep cannot see it. The opt-in pass
# reaps one only when its run is proven over, with a recovery window. A second
# opt-in pass reports, read-only, the secrets no reaper can attribute.

SWEEP_TEST_HARNESS_ONLY=1
# shellcheck source=test-sweep-orphaned-validation-infra.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-sweep-orphaned-validation-infra.sh"
export SWEEP_RETRY_DELAY_SECONDS=0

WRAP_BIN="$TMP_DIR/wrap-bin"
mkdir -p "$WRAP_BIN"
cat > "$WRAP_BIN/aws" <<WRAP
#!/usr/bin/env bash
set -uo pipefail
[[ "\$1 \$2" == "secretsmanager list-secrets" ]] || exec "$FAKE_BIN/aws" "\$@"
printf '%s\n' "\$*" >> "\$AWS_CALL_LOG"
[[ -z "\${FAKE_LIST_SECRETS_ERROR:-}" ]] || { echo "\$FAKE_LIST_SECRETS_ERROR" >&2; exit 254; }
prefix=""
[[ "\$*" =~ Key=name,Values=([^ ]+) ]] && prefix="\${BASH_REMATCH[1]}"
jq --arg p "\$prefix" '{SecretList: [.[] | select(.Name | startswith(\$p))]}' "\$FIXTURE_SECRETS"
WRAP
chmod +x "$WRAP_BIN/aws"
export PATH="$WRAP_BIN:$PATH"

secret() {
  # secret <name> [tags json]
  jq -cn --arg n "$1" --argjson t "${2:-[]}" \
    '{ARN: ("arn:aws:secretsmanager:us-west-2:1:secret:" + $n + "-AbCdEf"), Name: $n, Tags: $t}'
}
secrets() { jq -s . <<<"$(printf '%s\n' "$@")" > "$TMP_DIR/secrets.json"; export FIXTURE_SECRETS="$TMP_DIR/secrets.json"; }
arn_of() { echo "arn:aws:secretsmanager:us-west-2:1:secret:$1-AbCdEf"; }
verdict() { if eval "$2"; then check "$1" ok; else check "$1" no; fi; }
NONE="$(resources)"

DONE='honua-cloud-cell-state/111-1-aws-ecs-redis-on'
DONE_KEY='honua-cloud-cell-state/111-1-aws-ecs-redis-on-app-key'
RUNNING='honua-cloud-cell-state/222-1-aws-serverless-redis-off'
GRACE='honua-cloud-cell-state/333-2-aws-ecs-redis-off'
UNKNOWN='honua-cloud-cell-state/444-1-aws-ecs-redis-on'
MALFORMED='honua-cloud-cell-state/not-a-run'
STANDING='honua-cloud-cell-state/111-1-aws-ecs-redis-off'
secrets "$(secret "$DONE")" "$(secret "$DONE_KEY")" "$(secret "$RUNNING")" "$(secret "$GRACE")" \
  "$(secret "$UNKNOWN")" "$(secret "$MALFORMED")" \
  "$(secret "$STANDING" '[{"Key":"Environment","Value":"standing"}]')"

echo "== off by default =="
run_sweeper "$NONE"
verdict "without --cell-state-secrets no secret is listed" '[[ $RC -eq 0 ]] && ! grep -q "^secretsmanager list-secrets" "$AWS_CALL_LOG"'

echo "== reaping =="
run_sweeper "$NONE" --cell-state-secrets
assert_deleted "a finished run's state secret is deleted" "$(arn_of "$DONE")"
assert_deleted "its key secret is deleted too" "$(arn_of "$DONE_KEY")"
verdict "only the two finished secrets are planned" '[[ $RC -eq 0 && $(grep -c "^PLAN delete" <<<"$OUT") -eq 2 ]]'
verdict "deletion keeps a 7-day recovery window" \
  '[[ $(grep -c "^secretsmanager delete-secret .*--recovery-window-in-days 7" "$AWS_CALL_LOG") -eq 2 ]] && ! grep -q -- "--force-delete-without-recovery" "$AWS_CALL_LOG"'
verdict "the listing is fenced to the cell-state prefix" 'grep -q "^secretsmanager list-secrets .*Key=name,Values=honua-cloud-cell-state/" "$AWS_CALL_LOG"'
for name in "$RUNNING" "$GRACE" "$UNKNOWN" "$MALFORMED" "$STANDING"; do
  assert_not_planned "not planned: $name" "$(arn_of "$name")"
done
verdict "each refusal says why" 'grep -q "run 222 is .in_progress." <<<"$OUT" && grep -q "run 333 completed inside" <<<"$OUT" && grep -q "run 444 is .unknown." <<<"$OUT" && grep -q "$MALFORMED-AbCdEf | cell-state secret name does not name a GitHub run" <<<"$OUT"'

echo "== protection =="
run_sweeper "$NONE" --cell-state-secrets --protect-run-id gha-111-aws-ecs-redis-on
assert_not_planned "a protected run's state secret is kept" "$(arn_of "$DONE")"
FAKE_SECRET_DELETED_DATE=2026-11-20T00:00:00Z run_sweeper "$NONE" --cell-state-secrets
assert_no_mutations "a secret already scheduled for deletion is settled, not re-deleted"
FAKE_LIST_SECRETS_ERROR='An error occurred (AccessDeniedException) when calling the ListSecrets operation: x' \
  run_sweeper "$NONE" --cell-state-secrets
verdict "an unreadable listing fails the sweep and deletes nothing" '[[ $RC -ne 0 ]] && ! grep -Eq "$MUTATING" "$AWS_CALL_LOG"'
run_sweeper "$NONE" --cell-state-secrets --dry-run
assert_no_mutations "a dry run deletes nothing"
run_sweeper "$NONE" --cell-state-secrets --this-run --run-id gha-111-aws-ecs-redis-on
verdict "--this-run cannot reap cell-state secrets" '[[ $RC -ne 0 ]] && ! grep -Eq "$MUTATING" "$AWS_CALL_LOG"'

echo "== untagged report =="
secrets "$(secret 'legacy/orphan-one')" "$(secret "$DONE")" \
  "$(secret 'AdminSecret-x' '[{"Key":"aws:cloudformation:stack-name","Value":"honua-gate-2130z"}]')" \
  "$(secret 'honuar-cell' '[{"Key":"Owner","Value":"release-cell"}]')" \
  "$(secret 'legacy/orphan-two' '[{"Key":"Project","Value":"honua"}]')"
SUMMARY="$TMP_DIR/summary.md"; : > "$SUMMARY"
run_sweeper "$NONE" --report-untagged-secrets --summary-file "$SUMMARY"
verdict "the report lists exactly the unattributed secrets" \
  'grep -q "legacy/orphan-one" "$SUMMARY" && grep -q "legacy/orphan-two" "$SUMMARY" && ! grep -Eq "AdminSecret-x|honuar-cell|111-1-aws" "$SUMMARY"'
verdict "the report deletes nothing" '[[ $RC -eq 0 ]] && ! grep -Eq "$MUTATING" "$AWS_CALL_LOG"'

echo
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
