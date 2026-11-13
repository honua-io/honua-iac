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
- Kept: `workflow_run` requested, in_progress and completed with any outcome (fork runs dropped); external (non-Actions) `check_run`/`check_suite`;
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
     events: ["workflow_run","workflow_job","check_suite","check_run","pull_request","pull_request_review",
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

## Workflow lifecycle evidence

Workflow messages retain `run_status`, `run_attempt`, `run_event`, `workflow_path`,
`created_at` and `started_at` when GitHub supplies them. Existing v1 fields stay
compatible. Active messages omit `conclusion`; completed cancellations and skipped
runs are retained so a later consumer can retire active observations. These events
do not authorize a fixer, a workflow dispatch or a cancellation. The dispatcher
continues routing failures and successes under its existing rules.

The flow doctor's planned event ledger needs these messages before it can observe
active trunk runs without polling. Missing fields and missed deliveries remain
unknown. A run's path and trigger alone do not prove full-CI selection or a shared
concurrency group; cancellation still requires exact run, jobs and concurrency
validation. GitHub does not send the `requested` activity for reruns, so consumers
must also handle `in_progress` with `run_attempt` and out-of-order delivery.
See [GitHub workflow_run activity documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run).

Deployment of this code remains an operator action. On the operator workstation,
check out the merged commit, use the existing backend and private variables, then:

```bash
terraform -chdir=infrastructure/terraform/bootstrap/aws-ci-events init
terraform -chdir=infrastructure/terraform/bootstrap/aws-ci-events plan -out=ci-events.plan
terraform -chdir=infrastructure/terraform/bootstrap/aws-ci-events apply ci-events.plan
```

Review the saved plan before applying. No org webhook subscription change is
needed: `workflow_run` is already subscribed. No new resources, role permissions,
secret rotation or lane-host settings are required. Install the event-ledger
consumer separately through its reviewed release; deploying this receiver alone
does not complete or enable the doctor's blocking-run detector.

## Runner queue evidence

`workflow_job` queued/in_progress/completed messages retain job and run IDs,
requested runner labels, lifecycle timestamps and conclusion. Labels are bounded
to 32 entries of 100 characters; steps and raw job payloads are omitted. The
messages set `observation_only: true`: job payloads cannot attest a same-repository
head, and must never authorize fixers, reruns, pushes or cancellation. Fork jobs
are included as observations of capacity used in the webhook repository.

These are partial observations, not a complete queue inventory. Missing deliveries,
labels or lifecycle timestamps remain unknown. Queue age starts at the queued
job's creation timestamp, never the parent workflow creation time. See
[GitHub workflow_job events](https://docs.github.com/en/webhooks/webhook-events-and-payloads#workflow_job).

After the reviewed consumer is installed and this receiver is applied using the
saved-plan procedure above, main adds `workflow_job` to the existing org hook.
This preserves every currently subscribed event and does not read or rotate the secret:

```bash
hook_id=<existing-ci-events-hook-id>
gh api "orgs/honua-io/hooks/$hook_id" --jq '{events: ((.events + ["workflow_job"]) | unique)}' |
  gh api "orgs/honua-io/hooks/$hook_id" --method PATCH --input - --jq '{id, active, events}'
```

The command needs `admin:org_hook` access. Runtime activation remains main-owned;
receiver deployment alone does not make runner-queue telemetry available.
