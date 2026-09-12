#!/usr/bin/env bash

# Hermetic tests for verify_licensing_mode in run-aws-terraform-integration.sh
# (honua-iac #191, honua-server #4721).
#
# The 2026.1 candidate ships with licensing DISABLED, and the live harness has
# to FAIL a cell that reports anything else. The interesting cases are therefore
# the refusals — above all the Community fallback, which is the exact shape the
# server takes when it ignores the module's Licensing__Mode and loads its own
# Enabled default with no license source. A check that treated Community as
# "near enough" would pass a cell with editing/sync/streaming/geocoding gated
# off, which is the failure this test exists to prevent.
#
# No AWS credentials are used and no network call is made: a fake `curl` on PATH
# ahead of the real one serves a canned admin-license payload. The expected
# values are honua-server's published contract (mode "disabled", edition
# "Unlicensed-2026.1", validationState "Disabled" — see
# tests/dotnet/Honua.Server.Tests/Features/Licensing/DisabledLicenseIntegrationTests.cs),
# not a recording of what this harness currently produces.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$SCRIPT_DIR/run-aws-terraform-integration.sh"

if [[ ! -f "$HARNESS" ]]; then
  echo "[ERROR] harness not found: $HARNESS" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

# Fake curl: writes $FAKE_BODY_FILE to the -o target and echoes $FAKE_STATUS as
# the -w "%{http_code}" substitute, which is all verify_licensing_mode consumes.
cat > "$FAKE_BIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -uo pipefail
out=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then
    out="$arg"
  fi
  prev="$arg"
done
if [[ -n "$out" ]]; then
  cat "$FAKE_BODY_FILE" > "$out"
fi
printf '%s' "${FAKE_STATUS:-200}"
FAKE_CURL
chmod +x "$FAKE_BIN/curl"

FAILURES=0
CASES=0

# One case = one canned payload + expected verdict, run twice: once with jq on
# PATH and once without, because the function carries a grep/sed fallback parser
# and a fallback that silently returns an empty mode would pass every assertion
# it is supposed to fail.
run_case() {
  local name="$1"
  local expect="$2" # pass | fail
  local status="$3"
  local body="$4"
  local expected_mode_env="${5:-}"
  local jq_mode
  local body_file
  local output
  local rc

  body_file="$TMP_DIR/body.json"
  printf '%s' "$body" > "$body_file"

  for jq_mode in with-jq without-jq; do
    CASES=$((CASES + 1))
    local path_prefix="$FAKE_BIN"
    if [[ "$jq_mode" == "without-jq" ]]; then
      # A PATH holding only the fake curl: jq (and everything else the function
      # does not use) is unavailable, exercising the grep/sed parser.
      mkdir -p "$TMP_DIR/nojq"
      cp "$FAKE_BIN/curl" "$TMP_DIR/nojq/curl"
      for tool in grep sed tr cut mktemp rm head; do
        if [[ -x "$(command -v "$tool" 2>/dev/null)" && ! -e "$TMP_DIR/nojq/$tool" ]]; then
          ln -s "$(command -v "$tool")" "$TMP_DIR/nojq/$tool"
        fi
      done
      path_prefix="$TMP_DIR/nojq"
    fi

    output="$(
      PATH="$path_prefix:$PATH" \
      FAKE_BODY_FILE="$body_file" \
      FAKE_STATUS="$status" \
      HONUA_EXPECTED_LICENSING_MODE="$expected_mode_env" \
      bash -c '
        set -uo pipefail
        if [[ -z "${HONUA_EXPECTED_LICENSING_MODE:-}" ]]; then
          unset HONUA_EXPECTED_LICENSING_MODE
        fi
        # shellcheck disable=SC1090
        source "$1" >/dev/null 2>&1 || true
        HONUA_ADMIN_PASSWORD="synthetic-admin-key"
        verify_licensing_mode "https://cell.example.invalid"
      ' _ "$HARNESS" 2>&1
    )"
    rc=$?

    if [[ "$expect" == "pass" && "$rc" -ne 0 ]]; then
      echo "[FAIL] $name ($jq_mode): expected the check to pass, got rc=$rc"
      echo "       $output"
      FAILURES=$((FAILURES + 1))
    elif [[ "$expect" == "fail" && "$rc" -eq 0 ]]; then
      echo "[FAIL] $name ($jq_mode): expected the check to FAIL, but it passed"
      echo "       $output"
      FAILURES=$((FAILURES + 1))
    else
      echo "[ OK ] $name ($jq_mode)"
    fi
  done
}

DISABLED_BODY='{"data":{"mode":"disabled","edition":"Unlicensed-2026.1","validationState":"Disabled","isValid":true,"expiryWarning":false}}'
ENABLED_PRO_BODY='{"data":{"mode":"enabled","edition":"Pro","validationState":"Valid","isValid":true}}'
COMMUNITY_FALLBACK_BODY='{"data":{"mode":"enabled","edition":"Community","validationState":"NotFound","isValid":true}}'
DISABLED_BUT_COMMUNITY_BODY='{"data":{"mode":"disabled","edition":"Community","validationState":"Disabled","isValid":true}}'
DISABLED_BUT_VALIDATED_BODY='{"data":{"mode":"disabled","edition":"Unlicensed-2026.1","validationState":"Valid","isValid":true}}'

run_case "licensing-disabled cell is accepted" pass 200 "$DISABLED_BODY"

# The failure this check exists for: the server ignored Licensing__Mode, used its
# own Enabled default, found no license and served Community.
run_case "Community fallback is refused" fail 200 "$COMMUNITY_FALLBACK_BODY"

# A truthful mode with an untruthful edition is still a refusal: 2026.1 must not
# claim an edition it is not gating on.
run_case "disabled mode reporting a Community edition is refused" fail 200 "$DISABLED_BUT_COMMUNITY_BODY"

run_case "disabled mode reporting a validated license is refused" fail 200 "$DISABLED_BUT_VALIDATED_BODY"

run_case "a licensed cell is refused by default" fail 200 "$ENABLED_PRO_BODY"

# ... and accepted only when the operator says so.
run_case "a licensed cell is accepted when expected" pass 200 "$ENABLED_PRO_BODY" "enabled"

run_case "non-200 from the admin endpoint is refused" fail 500 "$DISABLED_BODY"
run_case "unauthorized admin endpoint is refused" fail 401 '{"error":"unauthorized"}'
run_case "a response with no mode field is refused" fail 200 '{"data":{"edition":"Unlicensed-2026.1"}}'
run_case "an empty body is refused" fail 200 ''

echo
if [[ "$FAILURES" -ne 0 ]]; then
  echo "[ERROR] $FAILURES/$CASES licensing-mode check cases failed" >&2
  exit 1
fi
echo "[INFO] all $CASES licensing-mode check cases passed"
