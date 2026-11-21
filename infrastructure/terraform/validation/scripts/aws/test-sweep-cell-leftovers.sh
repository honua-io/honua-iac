#!/usr/bin/env bash

# A torn-down cell also leaves Batch job definitions, an ACM certificate and a
# versioned ALB access-log bucket. Each needs a
# settled check and a deletion path, or every sweep plans it and reports it
# left behind forever.

SWEEP_TEST_HARNESS_ONLY=1
# shellcheck source=test-sweep-orphaned-validation-infra.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-sweep-orphaned-validation-infra.sh"
export SWEEP_RETRY_DELAY_SECONDS=0

# The reads these types need, in front of the shared fake; everything else,
# including every write, goes to it.
WRAP_BIN="$TMP_DIR/wrap-bin"
mkdir -p "$WRAP_BIN"
cat > "$WRAP_BIN/aws" <<WRAP
#!/usr/bin/env bash
set -uo pipefail
case "\$1 \$2" in
  "batch describe-job-definitions"|"acm describe-certificate"|"s3api get-bucket-location"|"s3api list-object-versions"|"s3api delete-objects")
    printf '%s\n' "\$*" >> "\$AWS_CALL_LOG" ;;
  *) exec "$FAKE_BIN/aws" "\$@" ;;
esac
arg_after() { local flag="\$1"; shift; while [[ \$# -gt 0 ]]; do [[ "\$1" == "\$flag" ]] && { echo "\$2"; return; }; shift; done; }
case "\$1 \$2" in
  "batch describe-job-definitions")
    jq -cn --arg arn "\$(arg_after --job-definitions "\$@")" --arg s "\${FAKE_JOBDEF_STATUS:-ACTIVE}" '{jobDefinitions:[{jobDefinitionArn:\$arn,status:\$s}]}' ;;
  "acm describe-certificate")
    jq -cn --arg arn "\$(arg_after --certificate-arn "\$@")" '{Certificate:{CertificateArn:\$arn,Status:"ISSUED"}}' ;;
  "s3api get-bucket-location")
    echo '{"LocationConstraint":"us-west-2"}' ;;
  "s3api list-object-versions")
    if grep -q '^s3api delete-objects ' "\$AWS_CALL_LOG" && [[ -z "\${FAKE_S3_DELETE_ERRORS:-}" ]]; then echo '{}'; else
      echo '{"Versions":[{"Key":"AWSLogs/a.log.gz","VersionId":"v1"}],"DeleteMarkers":[{"Key":"AWSLogs/b.log.gz","VersionId":"m1"}]}'
    fi ;;
  "s3api delete-objects")
    # A zero-exit response can still carry per-key failures.
    [[ -z "\${FAKE_S3_DELETE_ERRORS:-}" ]] || echo '{"Errors":[{"Key":"AWSLogs/a.log.gz","Code":"AccessDenied"}]}' ;;
esac
WRAP
chmod +x "$WRAP_BIN/aws"
export PATH="$WRAP_BIN:$PATH"

JOBDEF_ARN='arn:aws:batch:us-west-2:1:job-definition/honua-it-gp-s:1'
CERT_ARN='arn:aws:acm:us-west-2:1:certificate/0123abcd'
BUCKET_ARN='arn:aws:s3:::honua-it-alb-logs-cf0d63a0'
OTHER_BUCKET_ARN='arn:aws:s3:::honua-it-file-storage'
JOBDEF="$(tagged "$JOBDEF_ARN" 'gha-111-aws-ecs' 'ecs' "$PAST")"
CERT="$(tagged "$CERT_ARN" 'gha-111-aws-ecs' 'ecs' "$PAST")"
BUCKET="$(tagged "$BUCKET_ARN" 'gha-111-aws-ecs' 'ecs' "$PAST")"
OTHER_BUCKET="$(tagged "$OTHER_BUCKET_ARN" 'gha-111-aws-ecs' 'ecs' "$PAST")"
err() { echo "An error occurred ($1) when calling the $2 operation: fixture detail"; }
verdict() { if eval "$2"; then check "$1" ok; else check "$1" no; fi; }

echo "== Batch job definitions =="
FAKE_JOBDEF_STATUS=INACTIVE run_sweeper "$(resources "$JOBDEF")"
assert_not_planned "a deregistered job definition is not planned" "$JOBDEF_ARN"
assert_no_mutations "a deregistered job definition triggers no mutating call"
verdict "a deregistered job definition is settled and the sweep passes" '[[ $RC -eq 0 ]] && grep -q "Already settled (tag index lagging): $JOBDEF_ARN" <<<"$OUT"'
run_sweeper "$(resources "$JOBDEF")"
assert_deleted "an active job definition is deregistered" "$JOBDEF_ARN"
verdict "the deregister names the revision ARN" 'grep -q "^batch deregister-job-definition .*--job-definition $JOBDEF_ARN" "$AWS_CALL_LOG"'

echo "== ACM certificates =="
run_sweeper "$(resources "$CERT")"
assert_deleted "a cell certificate is deleted" "$CERT_ARN"
FAKE_WRITE_FAIL_ONCE="delete-certificate:$(err ResourceInUseException DeleteCertificate)" run_sweeper "$(resources "$CERT")"
verdict "a certificate still held by a deleting listener is retried" '[[ $RC -eq 0 ]] && [[ $(grep -c "^acm delete-certificate " "$AWS_CALL_LOG") -eq 2 ]]'
assert_deleted "the certificate is deleted on retry" "$CERT_ARN"

echo "== ALB access-log buckets =="
run_sweeper "$(resources "$BUCKET")"
verdict "without --delete-log-buckets a bucket is only reported" '[[ $RC -eq 0 ]] && ! grep -Eq "^s3api (list-object-versions|delete-)" "$AWS_CALL_LOG"'
run_sweeper "$(resources "$BUCKET")" --delete-log-buckets
assert_deleted "an ALB log bucket is deleted" "$BUCKET_ARN"
verdict "every version and delete marker goes before the bucket" \
  'grep -n "^s3api delete-objects .*AWSLogs/a.log.gz.*\"v1\".*AWSLogs/b.log.gz.*\"m1\"" "$AWS_CALL_LOG" | cut -d: -f1 | { read -r o; b=$(grep -n "^s3api delete-bucket " "$AWS_CALL_LOG" | cut -d: -f1); [[ -n "$o" && -n "$b" && $o -lt $b ]]; }'
FAKE_S3_DELETE_ERRORS=1 run_sweeper "$(resources "$BUCKET")" --delete-log-buckets
verdict "a bucket whose objects cannot all be deleted is kept" '[[ $RC -ne 0 ]] && ! grep -q "^s3api delete-bucket " "$AWS_CALL_LOG"'
run_sweeper "$(resources "$OTHER_BUCKET")" --delete-log-buckets
verdict "a bucket of any other shape is never emptied or deleted" '! grep -Eq "^s3api delete-(objects|bucket) " "$AWS_CALL_LOG"'

echo "== dry run =="
run_sweeper "$(resources "$JOBDEF" "$CERT" "$BUCKET")" --dry-run --delete-log-buckets
assert_no_mutations "a dry run over all three types triggers no mutating call"
verdict "a dry run plans all three" '[[ $(grep -c "^PLAN delete" <<<"$OUT") -eq 3 ]]'

echo
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
