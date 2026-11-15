# Gate member runtime

Main applies this root in the member account after the management stage.
See [gate test account](../aws-gate-account/README.md) for the private SSM input
schema, separate state, lane interface, budget limitations and live acceptance.

## Shared-account mode (no Organization or new account)

Main applies this root directly using existing-account bootstrap credentials.
Skip `aws-gate-account` entirely: its organization, linked-account budget and SCP
budget action are **not** used. Keep separate state for this runtime, and check
that the role, policy, function, log group and budget names are unused before
applying. Do not import unrelated existing resources into this state.

Main creates an SSM SecureString JSON object privately in `us-east-1` with these
fields (actual identifiers and recipient stay out of repository text):

| Field | Private value |
| --- | --- |
| `shared_account` | `true` |
| `member_account_id` | The existing account identifier, despite the legacy variable name |
| `lane_principal_arns` | Array containing the exact existing **lane host IAM role**; not an account root or user |
| `protected_state_buckets` | Array of every existing Terraform state bucket name, including this root's backend |
| `protected_ssm_paths` | Array of exact private parameter paths, including this runtime configuration and build-host configuration |
| `budget_alert_email` | Recipient for actual-cost alerts |

The loader's bootstrap identity needs SSM GetParameter, KMS Decrypt if applicable,
and access to the separate encrypted backend. The lane identity gets neither.
From this directory, main runs:

```bash
umask 077
python3 ../aws-gate-tools/gate_tools.py load-config "$GATE_RUNTIME_PARAMETER" terraform.tfvars.json
cp backend.tf.example backend.tf
# Edit the private backend copy: existing bucket, access role and a dedicated state key.
terraform init
terraform fmt -check
terraform validate
terraform plan -out=gate.tfplan
# Review the saved plan privately, including account, trust, denies and cost filter.
terraform apply gate.tfplan
```

Mark this root applied/operator in the private drift inventory when applying.
Use the three sensitive outputs privately for the lane assume-role target,
CloudFormation RoleARN and template permissions boundary, as described above.
No apply is performed by this change.

Every gate stack must carry the user tag `HonuaGate=true` (for example, supply
`--tags Key=HonuaGate,Value=true` to CloudFormation create and update commands). The lane policy denies creates
and updates that omit this tag or change its value.
Main must activate `HonuaGate` as a **user-defined cost allocation tag** in Billing
and verify its appearance in Cost Explorer before relying on the filter.
CloudFormation must propagate that tag to billable resources; check resources
that do not support stack-tag propagation separately. The shared monthly budget
filters `user:HonuaGate$true`, alerts by email above 80 percent of USD 300 actual
cost, and **does not stop spend**. Untagged or unallocatable charges are excluded;
billing and tag activation are delayed. There is no shared-account budget action
or automatic fence. Monitor total account cost and clean up resources promptly.

### Shared-resource protections and remaining limits

The lane policy/boundary, CloudFormation service policy and workload boundary
explicitly deny regional calls outside `us-east-1`; IAM, Route 53 and CloudFront
are the only global-service exceptions. The service and workload policies deny
all S3 access outside `honua-gate-*`, deny the named state buckets even if they
match that prefix, and deny all SSM access with the private parameters also
listed explicitly. Pre-existing buckets with the gate prefix are therefore a
name-collision risk: main must ensure the prefix is reserved exclusively for gate
stacks before granting access.

### Launch Stack services

The workload allow covers the parent template's default and optional resource
types that this boundary can fence: ACM, Application Auto Scaling, Backup, Batch,
Budgets, Cost Explorer anomaly monitors, CloudFront, CloudTrail, CloudWatch,
EC2, ECS, Elastic Load Balancing, EventBridge, GuardDuty, KMS, Lambda, Logs,
RDS, Route 53, S3, Secrets Manager, SNS, SQS and WAFv2, plus ECR image pulls.
GuardDuty may create its service-linked role. The same region, stack-tag and
content-read denies apply. Several AWS create calls are also the update call
(`budgets:ModifyBudget`, `cloudwatch:PutMetricAlarm`, `cloudwatch:PutCompositeAlarm`,
`events:PutRule`, `events:PutTargets`). A missing stack tag cannot distinguish
create from overwrite, so those calls are limited to `honua-gate-*` names.
`events:*` on `honua-gate-nightly-reaper` and `budgets:*` on
`honua-gate-shared-monthly` are denied even though those names match the prefix.

Still not grantable:

- `AWS::SSM::Parameter` (watchdog, off by default) and SSM documents. The template
  has no `AWS::SSM::Document`. `ssm:*` stays denied so private parameters cannot
  be read. A stack parameter allow would be a separate change to that deny.
- `AWS::Bedrock::*`, `AWS::BedrockAgentCore::*` and `AWS::IAM::ManagedPolicy`.
  They exist only on the agents child template, which defaults to Off. This role
  also has no `cloudformation:CreateStack`, so it cannot create that nested stack.
- Security Hub and EventBridge Scheduler. The template has neither resource type.
  Schedules in the parent template are `AWS::Events::Rule`.

Other existing-resource mutations require the immutable AWS-owned
`aws:cloudformation:stack-name` resource tag to match `honua-gate-*`. A missing tag
or unavailable condition key denies the request (`StringNotLikeIfExists` with
Deny); tag-changing calls are not exempt. Content-bearing reads use the same
ownership deny in both the CloudFormation service policy and workload boundary.
The service role still exempts Get, List and Describe plus enumerated allocation
APIs, because stabilizing a stack needs account-wide metadata. The workload
boundary does not repeat that metadata list: it is the statement that overflowed
the managed-policy quota. Workload reads and writes therefore require the gate
stack tag, and allocation APIs remain the only untagged workload exemption besides
named gate buckets. IAM PassRole remains restricted to gate role names and the
allowed receiving services. Actions outside the workload allow list are implicit
denies; the boundary does not repeat that allow list inside a second deny.
The default member-account mode is unchanged. See the
[content-read audit](content-read-controls.md) for covered APIs and unsupported
ownership conditions.

AWS does not expose this resource tag for every action. In particular, Route 53
record changes, untaggable CloudFront resources, Application Auto Scaling
registrations, some Logs operations, EC2 association/route operations and service
resources without CloudFormation tag propagation may be denied even for gate
resources. These are **not** blanket write exceptions: a live install or cleanup
can fail closed, requiring a reviewed policy adjustment. Check each action in the
[AWS service authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/reference.html)
before expanding permissions. The global exceptions bypass only the region deny,
not ownership checks.

Creation APIs cannot prove ownership of a resource that does not yet exist.
They can allocate resources using existing dependencies (for example network
subnets, clusters or load balancer parents). Service-linked roles are account-wide
and outside workload permissions boundaries; service operations performed by
those roles are not fenced by these policies. S3 ownership uses names rather
than stack tags. Metadata access for the CloudFormation service role is account-wide. Workload
roles get metadata only for gate-tagged resources.
Main must assess those shared-account limits, existing gate-prefixed names,
service-linked roles, tag propagation and supported resource types before a live
run. This identity is for reviewed gate templates; arbitrary untrusted templates
are not a supported shared-account boundary.

Before recording a live pass, main tests region denial for all three identity
paths, protection of pre-existing resources and private inputs, allowed gate
create/update/delete and cleanup, boundary enforcement and cost tag attribution.
The existing reaper retains its schedule, keep/protection behavior and failure
reporting. Offline mocked tests validate generated controls; they do not prove
AWS authorization, a successful install, cleanup or budget delivery.
