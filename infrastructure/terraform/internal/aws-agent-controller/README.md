# Agent controller accounting and evidence storage

Internal Terraform root for [release #622](https://github.com/honua-io/honua-release/issues/622),
part of [#619](https://github.com/honua-io/honua-release/issues/619). This provisions
the candidate's durable state substrate. It does not deploy an agent, grant
approval authority, execute a model, or qualify a workflow.

One root/state key is retained for a candidate across development, failures,
retries and qualification. The root creates an encrypted, private, versioned S3
bucket and two protected DynamoDB tables: the controller's fenced accounting head
and separate worker claim history with a candidate-wide active-worker record.
Launch and observed-stop records are immutable; only the fixed lifecycle can
transition the active-worker record. There are no servers or EC2 workers.

The controller role and Terraform deployment/recovery roles must already exist,
belong to the selected account, and have separate custody. Supply their exact
ARNs; workers, task execution roles, lifecycle roles and approvers do not belong
in the state administration list. The bucket and state-table resource policies
deny other principals, including workers with accidentally broad identity policies.
The controller policy permits only candidate-prefixed, create-only object writes,
exact-version reads, history inspection, and get/update of the candidate's state
head. Runtime bucket/table administration and deletion are explicitly denied.

The permanent `initialization.json`, snapshots and evidence require
`If-None-Match: *` on every object write. Copy and multipart upload are not enabled.
The S3 policy enforces this independently of controller code; see
[AWS conditional-write policy documentation](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes-enforce.html).
The controller still must use its fenced lease/CAS protocol: IAM cannot validate
the DynamoDB condition expression or turn a stale external operation into a safe
one. State administrators remain privileged recovery actors, not runtime actors.

## Integration

1. Reserve bootstrap, ongoing request/storage/PITR and retained-evidence liability
   in the candidate-wide ledger **before** applying this root. Keep that bootstrap
   history outside the not-yet-created stores. Do not initialize an empty ledger
   after apply. The reviewed bootstrap import/reconciliation path is still a
   release #622 prerequisite; this root does not solve it by granting a fresh budget.
2. Copy `backend.tf.example` to ignored `backend.tf` and select the existing
   governed Terraform backend, its access role, and a unique candidate state key.
   That Terraform backend is distinct from the runtime state bucket created here.
   Copy/fill `terraform.tfvars.example`. Use the repository's governed exact-plan
   and exact-apply workflow with the separate deployment role.
3. Export `state_config` to the trusted controller only. Its `region`, `bucket`
   and `table` fields match `agent_e2e_state.open_store`. Export
   `claim_table_name` to the separate `internal/aws-agent-worker` root. Its
   lifecycle policy may transactionally put only its exact attempt, candidate
   active-worker and immutable stop-record keys;
   it receives no access to the state table or evidence bucket.
   Set `claim_writer_role_arns` to the exact reviewed lifecycle role ARNs before
   starting those jobs. The default empty set deliberately disables runtime claim
   writes. Remove launch authority when retiring an attempt. The named roles must
   retain the worker root's service-only trust and fixed, conditional PutItem
   state-machine definition; IAM cannot enforce `attribute_not_exists` itself.
   Other runtime principals cannot put claims even with broad identity policies.
   Transaction writes are limited to the reviewed lifecycle roles through
   `dynamodb:EnclosingOperation`; other runtime principals cannot use them, since
   [transactions authorize underlying item actions](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/transaction-apis-iam.html).
   Transaction reads remain denied to runtime roles. The lifecycle uses atomic
   attempt/candidate acquisition and observed-stop recording; ACTIVE does not
   expire and is never released by controller lease takeover. Upgrade both roots
   together and prohibit older worker definitions during campaign preflight.
   All other runtime claim-table mutations, including disabling PITR, are denied.
4. Independently demonstrate actual role denials, versioned writes, concurrent
   writer fencing, controller-loss recovery and retained charges before running a
   paid agent campaign. Offline Terraform tests do not establish these properties
   on a deployed account. Keep #619's full live matrix unqualified until proven.

## Retention, cleanup and cost

These stores are retained accounting evidence, separate from disposable attempt
resources. No S3 expiration/noncurrent-version rule or DynamoDB TTL is configured.
Bucket force deletion is disabled; both tables have deletion protection and PITR;
Terraform `prevent_destroy` protects the bucket and tables. Attempt cleanup must
not destroy this root or remove launch claims. Runtime principals cannot remove
objects, versions or heads, nor disable these protections. This prevents lost
history from silently creating another $500 allowance.

Retained storage, PITR and requests are billable and belong in #619's existing
$500 ceiling, including its protected $50 cleanup reserve. A reviewed bound must
cover the full evidence retention and archival period before apply; do not treat
stopping a worker as terminating these charges. The final archival/decommission
procedure must first disable all candidate launch authority and establish retained
history that cannot be mistaken for a new candidate. Removing protection or
destroying stores is a separate reviewed state-administration operation, never an
automatic response to a missing head, failed attempt or exhausted budget.

The root does not create the shared Fargate network/cluster, publish images,
provide Docker CI isolation, configure monitored alert destinations or implement
the full teardown workflow. Those remain under release #621. It also does not
grant Bedrock, queue or deployment permissions to the controller; those are
separate scoped policies in the owning roots.

## Offline checks

```sh
terraform init -backend=false -input=false -lockfile=readonly
terraform validate
terraform test
```

Tests use a mock AWS provider (Terraform 1.7+), never credentials or live resources.
The root itself retains the repository's Terraform 1.5 minimum.
