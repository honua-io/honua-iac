# Agent E2E Fargate attempt

Internal infrastructure for honua-release #619. This root defines one isolated
attempt's FIFO command/reply queues, task identity, pinned non-root Fargate task
and a Step Functions launch lifecycle. It creates no EC2 instance or SSM transport.
Execution input cannot override the task, image, role, network or expiry.

The caller must reserve the full infrastructure liability before apply. Supply
an existing isolated cluster/network and durable controller claim table. Activate
a remote encrypted/locked backend with a unique key per attempt. Retain the exact
plan, IaC revision and state lineage; never share state with a customer deployment.

Start the emitted state machine only through the trusted controller. One DynamoDB
transaction creates an immutable attempt claim and acquires the candidate-wide
active-worker claim. An existing attempt cannot launch again, and another attempt
cannot launch while the candidate claim is ACTIVE. Neither controller lease
expiry nor worker expiry permits takeover. Never delete claims, reuse queues or
grant execution redrive. An authorized retry needs a new identity and independently
supported retry authorization in the controller.

The fixed lifecycle rechecks absolute expiry after claiming, starts exactly one
Fargate task with an attempt-specific client token, then polls that exact task.
Launch failures, missing/foreign observations and API errors retain the active
claim. Only DescribeTasks reporting the matching task, cluster and task-definition
revision as STOPPED permits a second transaction: append an immutable per-attempt
stop record and mark the matching candidate claim STOPPED. The condition includes
the execution ARN and attempt, so a stale execution cannot release a successor's
claim. The next attempt retains its predecessor's immutable launch/stop records.

For normal early cleanup, the controller output permits DescribeTasks/StopTask
only for this cluster and exact candidate/attempt resource tags. StopTask requests
do not release the claim; the lifecycle must observe STOPPED. At absolute expiry,
the lifecycle also requests stop, in addition to the independent reaper below.
Do not abort the lifecycle as normal cleanup: interrupted/timed-out lifecycle
executions deliberately leave ACTIVE claims for governed reconciliation. A
StopExecution response, missing task listing, elapsed time or expired controller
lease is not evidence that the worker stopped. Lost launch acknowledgements may
leave a real task; the reaper still enumerates its fixed family. Retain the claim
until an independently authorized recovery proves all launches terminal and all
owned tasks stopped. Automated recovery of such retained claims remains a backend
integration requirement; never manually clear one merely to continue testing.

The worker and controller-storage roots must be upgraded together: only reviewed
lifecycle roles may make transactional PutItem calls on their exact attempt,
candidate and stop-record keys. No UpdateItem/DeleteItem or runtime TTL authority
is introduced. IAM cannot enforce DynamoDB condition-expression contents, so the
fixed state-machine definition and service-only role trust remain part of the
boundary. A campaign must not mix older unfenced worker definitions with this
lifecycle. Freeze and verify the actual IaC and definition revisions in preflight.

Reserve DynamoDB transaction requests, the five-second task polling interval,
bounded API calls and up to 300 seconds of lifecycle observation beyond the worker
lifetime before starting. Lifecycle success only means the worker stopped and its
claim was recorded; it does not mean the agent goal, application cleanup or
accounting passed. Retain native execution history and stop records independently.

The task can only read/delete its command messages and send its own replies. Its
execution role can pull the pinned repository and write its log group. Neither
identity can read controller evidence or approve a goal. Replies are untrusted.
No controller/approval credentials belong in task environment variables.

The image must include the container runtime from honua-release, its pinned SDK
dependencies, bash and a UID 10001-writable /workspace and /journal volume layout.
The entrypoint must load only immutable /app modules, not workspace Python files.

## Agent MCP credential delivery

For MCP actions, set `mcp_configuration` to the ARN of an existing Terraform-owned
secret named `honua-agent-<attempt_id>-mcp`, its immutable version ID, and its KMS
key ARN when a customer-managed key is used. The ARN includes Secrets Manager's
six-character suffix. Both secret and key must belong to the reviewed account and
region; the secret name must match this exact attempt. Tag the secret with
`honua-agent-attempt` and `honua-agent-candidate` matching the root inputs.

```hcl
mcp_configuration = {
  secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-agent-example-attempt-mcp-AbCdEf"
  version_id = "12345678-1234-1234-1234-123456789abc"
  # kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789abc"
}
```

Supply metadata only. This root never reads or writes secret values, and no
credential bytes belong in tfvars, Terraform state, task-definition `environment`,
plan artifacts or outputs. The trusted runtime credential custodian populates
the already-provisioned secret and retains the resulting version ID. Do not use
a moving label such as `AWSCURRENT`. The value must be a JSON object of at most
16 KiB with exactly `endpoint`, `credentialKind`, `credential` and `workflowView`,
as documented by honua-release's MCP worker. `credentialKind` is `bearer` or
`api-key`; `workflowView` is `setup` for standard discovery. Anonymous negative
tests explicitly use a null credential. Supply only the tested agent identity,
never the observer, controller or separate approval identity.

ECS injects that version into `HONUA_AGENT_MCP_CONFIG` through the `secrets` field.
The fixed Fargate 1.4.0 task supports explicit secret-version selection. Only the
execution role receives `GetSecretValue`, scoped to the exact ARN, version,
ownership tags and fixed attempt expiry. A customer-managed key adds only
`kms:Decrypt`, restricted to Secrets Manager in this region and the exact secret
and version encryption context. The task's AWS role still grants only its own
queue operations. No permission to create, update, list or delete secrets is added.
The launch state machine waits for these policies and cannot accept task overrides.

The injected application credential is readable by code in this worker. Its own
Honua scope must therefore enforce the scenario's permissions. Expiring secret
retrieval does **not** revoke an already-injected token. Independently revoke
application credentials and verify denial during cleanup. P01/P24 require the
separate approval/bootstrap revocation and fresh unprivileged worker handoff;
rotating a secret on an existing task cannot substitute for those steps. Never
restart a claimed worker or reuse its queues after credential changes or failure.

Null `mcp_configuration` retains terminal-only transport testing without secret
permissions; it is not readiness for the complete campaign. Backend preflight must
inspect `mcp_configuration_binding`, verify the pinned version's actual actor,
tenant, grants and endpoint, and exercise delivery from the private subnets.
Include Secrets Manager reachability in the reviewed network; provisioning any
needed VPC endpoint and its policy belongs to the shared Terraform stack. Reserve
secret storage, reads, KMS usage and retained teardown liability before apply.

Mock-provider contracts verify rendered permissions and references, not live
secret delivery or application authorization. No secret or worker was created by
these tests. Full credential custody, deployed deny probes and revocation proof
remain acceptance requirements under release #619.

Contracts: [ECS secret-version injection](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html),
[Secrets Manager authorization](https://docs.aws.amazon.com/service-authorization/latest/reference/list_secretsmanager.html),
and [Secrets Manager encryption context](https://docs.aws.amazon.com/secretsmanager/latest/userguide/security-encryption.html).

## Independent expiry cleanup

Terraform defines a separate Standard Step Functions cleanup machine and an
EventBridge Scheduler invocation every minute from the absolute expiry until
24 hours later. The launch machine is created after that schedule and its alarms.
Cleanup does not depend on the worker, its queues, the controller or the launch
execution. Invocation input cannot choose a cluster, family, task or expiry.

The reaper refuses early execution, enumerates the exact attempt's Fargate task
family (including all result pages), stops owned tasks, and polls DescribeTasks
until each reports STOPPED. Its IAM scope additionally requires the exact cluster,
attempt and candidate resource tags. It cannot start tasks or provision resources.
The RUNNING desired-status filter includes tasks that are still provisioning;
AWS never assigns a PENDING desired status. Repeated scheduled invocations cover
delayed visibility, late launches and transient cleanup failures. Each cleanup
execution is bounded to five minutes. API failures and unobserved tasks fail the
execution, rather than claiming cleanup completed.

Scheduler delivery failures go to a dedicated encrypted dead-letter queue.
CloudWatch alarms for that queue and failed/timed-out/aborted cleanup executions
publish to the required `cleanup_alarm_topic_arn`. The caller must provide a
monitored standard SNS topic with confirmed subscriptions and prove alarm delivery
in preflight. Alarm existence alone does not demonstrate operator notification.

Reserve costs for the complete 24-hour safety window, scheduler retries, cleanup
executions, alarms, retained queues/logs and infrastructure teardown before apply.
Neither a stop request nor an empty eventually consistent list releases liability.
The controller must independently reconcile task IDs, observed STOPPED states and
usage, retain launch/reaper execution histories, then destroy the attempt root
through Terraform. Retain claim/accounting history in the separate durable store.
Do not destroy the schedule while an owned task or launch execution is unresolved.
An outage past the safety window requires operator reconciliation and blocks
qualification; do not reinterpret the bounded schedule as a cleanup guarantee.

This root is not a complete deployed campaign. Shared infrastructure, the Docker
lane, full scenario image, live boundary tests and a controller-loss cleanup drill
remain required. No resources were deployed by the offline validation. Do not
infer qualification from Terraform validation or a successful task exit.

API contracts: [ECS ListTasks](https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_ListTasks.html),
[ECS authorization](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ecs.html),
[DynamoDB transactions](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_TransactWriteItems.html),
[SDK integrations](https://docs.aws.amazon.com/step-functions/latest/dg/supported-services-awssdk.html),
and [Scheduler with Step Functions](https://docs.aws.amazon.com/step-functions/latest/dg/using-eventbridge-scheduler.html).
