# CI events receiver

Delivers GitHub CI and review events to the lane host within seconds, so `ci-dispatch` (honua-skills
`tools/lane/ci-events/`) can re-run an infrastructure failure, sync a PR with trunk, or start a one-shot
fixer as soon as a check goes red.

```text
GitHub org webhook ──HTTPS──> Lambda function URL ──> SQS honua-ci-events ──long-poll──> ci-dispatch (lane host)
                              verify X-Hub-Signature-256      │ 5 receives
                              drop unneeded events            └──> SQS honua-ci-events-dlq
                              compact JSON message
```

- Python 3.12, standard library plus the runtime's boto3; no packaged dependencies and no model calls.
- The webhook secret lives only in SSM SecureString `/honua/ci-events/webhook-secret`; the function reads
  it at run time (cached 5 minutes), so it never enters Terraform state.
- Kept: `workflow_run` completed with failure, timed_out, startup_failure, action_required or success (fork runs dropped); external (non-Actions) `check_run`/`check_suite`;
  `status` failure/error/success; `pull_request` opened/reopened/synchronize/closed/ready_for_review (same-repo
  heads only); `pull_request_review` submitted with changes requested or comments;
  `pull_request_review_comment` created; `pull_request_review_thread` unresolved; `issue_comment` created on a PR.
  Review and comment events are kept only from OWNER/MEMBER/COLLABORATOR authors or GitHub Apps (`[bot]`), and
  never for fork PRs (issue comments carry no head repo; ci-dispatch checks that before acting): a stranger's comment on a public repository must not start a fixer.
  Everything else gets 202 "dropped". A bad signature gets 401.
- Queue and dead-letter queue keep messages 4 days; SSE on; the receiver's concurrency is capped at 20.
- The lane host's instance role gets receive/delete on this queue only, through `ci_events_queue_arn` in
  `bootstrap/aws-lane-host`.

Unit tests: `python3 -m unittest discover -s lambda -p 'test_*.py'`; plan contract: `terraform test`.

## Apply (operator workstation, eu-north-1)

1. Secret (generated locally, never echoed):

   ```bash
   umask 077; openssl rand -hex 32 | tr -d '\n' > ~/honua-private/ci-events-webhook-secret
   aws ssm put-parameter --region eu-north-1 --type SecureString --overwrite \
     --name /honua/ci-events/webhook-secret --value "file://$HOME/honua-private/ci-events-webhook-secret"
   ```

2. This root:

   ```bash
   cd infrastructure/terraform/bootstrap/aws-ci-events
   cp backend.tf.example backend.tf      # set the state bucket
   terraform init
   terraform plan -out ci-events.plan
   terraform apply ci-events.plan
   terraform output -raw queue_url       # -> the dispatcher host's ci-events/queue-url
   ```

3. Lane host role (targeted, so nothing else in that root changes):

   ```bash
   cd ../aws-lane-host
   terraform plan -target=aws_iam_role_policy.ci_events \
     -var-file=<lane host tfvars from SSM /honua/lane-host/tfvars> \
     -var "ci_events_queue_arn=$(terraform -chdir=../aws-ci-events output -raw queue_arn)" -out ci-events.plan
   terraform apply ci-events.plan
   ```

   Add `ci_events_queue_arn` to the lane host tfvars in SSM so later full applies keep the policy.

4. Organisation webhook (needs a token with `admin:org_hook`; the secret is read from the file, never printed):

   ```bash
   url=$(terraform -chdir=infrastructure/terraform/bootstrap/aws-ci-events output -raw function_url)
   jq -n --arg url "$url" --rawfile secret ~/honua-private/ci-events-webhook-secret '{
     name: "web", active: true,
     events: ["workflow_run","check_suite","check_run","pull_request","pull_request_review",
              "pull_request_review_comment","pull_request_review_thread","issue_comment","status"],
     config: {url: $url, content_type: "json", insecure_ssl: "0", secret: $secret}}' |
     gh api orgs/honua-io/hooks --method POST --input - --jq '{id, active, events}'
   ```

   GitHub sends a `ping`; the receiver answers 200. `gh api orgs/honua-io/hooks/<id>/deliveries --jq '.[0:5][]|{event,status_code}'`
   shows recent deliveries.

5. `aws-ci-events` is `"applied": true` in `../drift-roots.json`; the nightly drift plan reads it with the SQS, Lambda and CloudWatch Logs reads `aws-drift-plan` grants bootstrap roots (apply `aws-drift-plan` first).

## Rotate the secret

GitHub does not retry failed deliveries, so rotate in this order (the receiver re-reads the parameter at most
once a minute when a signature does not match; deliveries in the switch-over can still fail for up to about a
minute, and GitHub does not retry them, so rotate in a quiet period):

```bash
umask 077; openssl rand -hex 32 | tr -d '\n' > ~/honua-private/ci-events-webhook-secret
aws ssm put-parameter --region eu-north-1 --type SecureString --overwrite \
  --name /honua/ci-events/webhook-secret --value "file://$HOME/honua-private/ci-events-webhook-secret"
jq -n --arg url "$(terraform output -raw function_url)" --rawfile secret ~/honua-private/ci-events-webhook-secret \
  '{url: $url, content_type: "json", insecure_ssl: "0", secret: $secret}' |
  gh api orgs/honua-io/hooks/<id>/config --method PATCH --input - --jq .url
```

The secret is only ever read from the file, never placed on a command line.
