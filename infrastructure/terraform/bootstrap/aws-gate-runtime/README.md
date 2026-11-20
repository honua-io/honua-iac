# Gate member runtime

Main applies this root in the member account after the management stage.
See [gate test account](../aws-gate-account/README.md) for the private SSM input
schema, separate state, lane interface, budget limitations and live acceptance.

## Shared-account mode (no Organization or new account)

Main applies this root directly using existing-account bootstrap credentials.
Skip `aws-gate-account` entirely: its organization, linked-account budget and SCP
budget action are **not** used. Keep separate state for this runtime, and check
that the role, policy, function, log group and budget names are unused before
applying. In shared-account mode also check that no account log resource policy
is named `honua-gate-waf-logs` (a put replaces it) and that us-east-1 holds
fewer than 10 account log resource policies. Do not import unrelated existing resources into this state.

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
Use the sensitive outputs privately for the lane assume-role target,
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
all S3 access outside `honua-gate-*` and deny the named state buckets even if
they match that prefix (the workload boundary lists only state buckets inside the
prefix, since the bucket deny already covers the rest, each as one `<name>*`
pattern that also denies longer bucket names, so a gate bucket whose name starts
with a state bucket's name is refused; one such bucket fits the 6,144-character
quota up to about 40 characters, and a longer one or a second one fails the apply). Pre-existing buckets with the gate prefix are therefore a
name-collision risk: main must ensure the prefix is reserved exclusively for gate
stacks before granting access.

`cloudwatch:PutMetricData` takes no resource, so the workload boundary exempts it
from the gate ownership deny; otherwise the server's operations heartbeat and the
watchdog heartbeat are denied on every gate install. Any gate workload can
therefore write metrics to any namespace in the shared account, which can move
another stack's metric alarms (and their actions) into or out of alarm. The
template's role policies limit each heartbeat to its own namespace
(`Honua/Operations`, `Honua/Watchdog`); metric writes read no content.

SSM is allowed only on gate stack watchdog parameters
(`/honua/honua-gate-*/watchdog/*`), and the service policy denies SSM outside
that path. `protected_ssm_paths` must stay outside it, and main must likewise
keep the `/honua/honua-gate-*` parameter path free of private parameters. Any
gate stack can write another gate stack's watchdog parameters; the template's
own role policies are the per-stack fence.

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
create from overwrite, so those calls are limited to `honua-gate-*` names
(composite alarms: see the service-role exceptions below).
`events:*` on `honua-gate-nightly-reaper` and `budgets:*` on
`honua-gate-shared-monthly` are denied even though those names match the prefix.

AWS Config: the stack's recorder function finds the account's recorder or
creates, starts and (when its create rolls back) removes its own, so the
boundary allows `config:*Recorder*` and `config:*DeliveryChannel*` and exempts
them from the ownership deny, and it may pass a gate role to
`config.amazonaws.com`. Recorders and delivery channels are account and Region
singletons with no tag context, so any gate workload can describe, replace,
stop or delete the account's recorder and channel in `us-east-1`. The pattern
also matches the service-linked recorder APIs: creating one needs
`iam:CreateServiceLinkedRole`, which the boundary never allows, but any gate
workload can delete an AWS service's service-linked recorder. Keep production
Config recording out of the shared gate account. Recorded resource
configuration (`config:Get*`, `config:Select*`) stays denied to workloads.

A recorder a gate stack creates outlives the stack by design, and neither the
lane role nor the reaper can remove it. Later gate stacks then take the
existing-recorder path and deliver through the first stack's retained role and
bucket. Keep those until the account administrator (main) stops and deletes
the recorder and its delivery channel, which is part of the gate teardown
after the Config rows; deleting the retained role or bucket first makes
recording fail silently.

The stack's drift rule is the service role's (below). Its evaluation role
carries the boundary, which allows no CloudFormation drift calls, so gate
stacks prove that the rule exists, not its drift verdict. Expect the rule to
report an error or noncompliance in the gate, and the stack's operations topic
to receive a daily drift message; that is gate noise, not a finding.

The CloudFormation service role alone allows `backup-storage:MountCapsule`,
which AWS Backup requires to create a vault and which has no resource-level
permissions. It bypasses the ownership-tag deny for that exact action. Failed
creates can also leave subnet groups without ownership tags, so service-role
`rds:DeleteDBSubnetGroup` is fenced to `honua-gate-*` subnet groups in the member
account and gate region. Neither exception extends the workload boundary.

Still not grantable:

- SSM outside the watchdog's own `/honua/<stack>/watchdog/state` and `mode`
  parameters, and SSM documents. The template has no `AWS::SSM::Document`.
  `PutParameter` creates and updates in one call and a new parameter has no stack
  tag, so the parameter name, not the ownership tag, scopes these calls.
- The watchdog health rule while the template names it `honua-health-*`, which
  the events name fence denies; it must be named under the stack's
  `honua-gate-*` name before a gate install can run the watchdog.
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
IAM and KMS reject tags with the `aws:` prefix, so CloudFormation never puts the
stack-name tag on a gate stack's roles and keys. The ownership deny therefore also
accepts the stack's required `HonuaGate=true` tag, which CloudFormation propagates
to them: it denies only when a resource has neither tag. Every gate stack must be
created and updated with that tag, and gate principals cannot add it to a
resource they do not already own, because tag changes sit behind the same deny.
The tag is weaker than the stack-name tag: it applies to every service, not only
IAM and KMS, and anyone with tagging rights outside the gate can set it. Never
put `HonuaGate=true` on a resource that is not a disposable gate resource (the
cost budget filters on the same tag), and expect any gate stack to be able to
change another gate stack's resources. Scoping it to IAM and KMS does not fit
the managed-policy quota.
A new KMS key has no tags yet when KMS runs its policy lockout check, so the gate
binder (`aws-gate-tools/gate_tools.py bind-template`) sets
`BypassPolicyLockoutSafetyCheck` on every key in the bound copy. It refuses a key
whose policy does not keep unconditional account-root administration.
Member mode has no shared budget, region deny or shared-account resource denies. It does allow these Launch Stack services and the name fence. See the
[content-read audit](content-read-controls.md) for covered APIs and unsupported
ownership conditions.

Two exceptions apply to the CloudFormation service role only, never to workload
roles; a full Launch Stack create needs both:

- **Creation tags.** EC2 and RDS handlers can tag a newly created resource
  before it has ownership tags. EC2 `CreateTags` requires the reserved
  `aws:cloudformation:stack-name` request tag matching `honua-gate-*` when no
  existing ownership tag matches. RDS `AddTagsToResource` instead accepts
  `HonuaGate=true` for gate-prefixed DB instance, cluster, subnet-group,
  parameter-group, option-group and snapshot ARNs in this account and region.
  An independent name deny applies even when the request carries the reserved
  stack tag; foreign names, accounts, regions and other RDS resource types stay
  denied. This narrowly permits the RDS create-then-tag sequence. Restore and
  copy operations retain the ownership deny on their source resources.
- **Untaggable CloudFront types.** Cache, origin-request and response-headers
  policies and origin access controls cannot carry tags, their create calls take no
  resource and their other calls name a random ID. The service role may create,
  read, update and delete any of them in the account; CloudFront refuses to delete
  a policy still attached to a distribution. CloudFormation only changes resources
  its stack owns, but a third-party or private registry resource type runs with the
  service role's credentials; keep such types deactivated in the shared account.
  CloudFront functions are fenced by name (`function/honua-gate-*`): set the Launch
  Stack `NamePrefix` to `honua-gate`, or the function is created and then orphaned.
- **AWS managed rule groups in a web ACL.** `wafv2:UpdateWebACL` is also
  authorized against each AWS managed rule group the ACL references, and those carry
  no tags. The service role is exempt from the ownership deny for this account's
  `managedruleset` ARNs only, so a stack update can change its web ACL's rules. The
  web ACL itself stays fenced by its ownership tags.
- **Route 53 health checks and CloudFront monitoring subscriptions.** The Launch
  Stack's public edge probe and real-time edge metrics have the same shape: create
  takes no resource, later calls name a random health-check ID or none at all, and
  neither service supports tag condition keys. The service role may therefore
  create, update and delete any health check in the account, and create, read and
  delete the monitoring subscription of any distribution. Unlike the CloudFront
  policies, nothing protects a health check that other records still use: an
  update can invert or disable it and a delete removes it, which would change
  failover for any non-gate record that depends on it; a subscription change adds
  or removes metrics charges on a foreign distribution. The same conditions hold:
  only CloudFormation uses the role, and third-party resource types stay
  deactivated. Keep production failover health checks and distributions out of the
  shared gate account. Hosted zones and their records keep the ownership fence.
- **ECS task definition deregistration and CloudFront continuous-deployment
  policies.** `ecs:DeregisterTaskDefinition` takes no resource and no condition key,
  so stack teardown cannot be fenced: the service role may deregister any task
  definition revision in the account. That cannot be undone: existing services keep
  running, but new tasks, services and service updates can no longer use the
  revision. The CloudFront `Create*Policy` pattern also admits creating an
  unattached continuous-deployment policy; attaching one needs `UpdateDistribution`,
  which keeps the fence. Same conditions as above.
- **CloudWatch composite alarms.** CloudWatch authorizes the CloudFormation
  composite-alarm create against the literal `alarm:*`, not only the alarm's name
  (seen live), so the service role's name fence also accepts `alarm:${*}`, the IAM
  variable for a literal asterisk. Metric alarms keep the `honua-gate-*` fence. If
  CloudWatch does not also check the named alarm, the service role may create, or
  overwrite the rule and actions of, any composite alarm in the account. The same
  conditions hold: only CloudFormation uses the role and third-party resource types
  stay deactivated. Keep production composite alarms out of the shared gate
  account. The workload boundary keeps the strict fence.
- **AWS Config rules.** CloudFormation cannot tag a Config rule and its ARN
  holds a random ID, so neither tag nor name can fence the stack's drift rule.
  The service role may manage any Config rule in the account through
  `config:*ConfigRule*`, exempt from the ownership deny. The organization and
  aggregate rule APIs in that pattern need an organization or aggregator the
  gate account does not have. Same conditions as above; keep production Config
  rules out of the shared gate account.

`HonuaGateLane` can inspect EC2 resources with `ec2:Describe*` and read KMS key
ownership tags with `kms:ListResourceTags`. Both the lane policy and its permissions
boundary include these reads. KMS reads name only keys in the configured gate
account and `us-east-1`; the existing region deny also limits EC2 inspection.
Both policies explicitly deny the EC2 Describe APIs classified as content reads
in `content-reads.tf`, including reads of gate-owned resources.

Security proofs evaluate a gate role without assuming it: `HonuaGateLane` may
call `iam:SimulatePrincipalPolicy` and `iam:GetContextKeysForPrincipalPolicy` on
`honua-gate-*` roles. The simulator returns a decision and the matching
statement positions for the role's deployed policies and boundary. It returns
no credentials and no policy text that `GetTemplate` does not already show.

Qualification rows must observe a running install (sidecar image digest, WAF log
redaction, the database role in use, Batch worker output). For that, both lane
policies also allow these read-only calls, on gate resources only:

- `ecs:ListTasks` where the cluster is named `honua-gate-*-Cluster-*`, and
  `ecs:DescribeTasks` and `ecs:DescribeServices` on tasks and services in those
  clusters. CloudFormation names each cluster `<stack name>-Cluster-<random>`.
  Upgrade and rollback rows read the service's rollout and circuit-breaker state.
- `cloudwatch:DescribeAlarms` and `cloudwatch:DescribeAlarmHistory` on alarms named
  `honua-gate-*` (a Launch Stack names its alarms `<stack name>-ops-*`), for
  alerting rows. No alarm writes and no `SetAlarmState`. Call them with explicit
  `--alarm-names` (or `--alarm-name` for history), taken from `ListStackResources`:
  a prefix or unfiltered call is authorized against `alarm:*` and is denied. The
  target-tracking alarms that Application Auto Scaling creates
  (`TargetTracking-service/<cluster>/...`) are outside the fence.
- `cloudfront:GetVpcOrigin` and `cloudfront:ListTagsForResource` on VPC origins,
  for teardown (see Gate test domain). These have no tag scope: with one, a
  deleted origin would also answer AccessDenied.
- `iam:GetRole` on `honua-gate-*` roles, next to the policy simulator, so a
  security row can read a gate role's trust policy and boundary.
- `logs:DescribeLogStreams`, `logs:FilterLogEvents` and `logs:GetLogEvents` on the
  log groups `/honua/honua-gate-*`, `aws-waf-logs-honua-gate-*` and
  `/aws/rds/instance/honua-gate-*`. CloudWatch Logs has no resource-tag condition
  for these calls, so the name is the fence. Reaper Lambda logs are not included.

These are content reads of gate installs, which hold synthetic qualification data
only. The lane still cannot read task definitions: `ecs:DescribeTaskDefinition` has no
resource scope and would expose every task definition in the account. To check the
container user or secret references, check that the running task's
`taskDefinitionArn` matches the task definition in `ListStackResources`. If it
matches, read that definition in `GetTemplate`, with parameter values from
`DescribeStacks`. During an update or rollback a task can still run an older
revision; then this check does not apply. Batch job reads, WAF API reads, log
queries and command execution are not granted either: Batch job APIs have no
resource scope, and WAF redaction shows in the WAF log records.

Rows that check Config recording and log retention need account-wide metadata
reads, because these APIs have no useful name scope. Both lane policies allow
`config:DescribeConfigurationRecorder*`, `config:DescribeDeliveryChannel*`,
`config:DescribeConfigRule*` and `config:DescribeComplianceByConfigRule`
(recorder and delivery status, rule scope, evaluation status and per-rule
compliance), and `logs:DescribeLogGroups`, which lists every log group name and
retention in the account, not only gate ones. They also allow
`logs:DescribeDeliveries`, `logs:DescribeDeliveryDestinations` and
`logs:DescribeDeliverySources` (one `logs:DescribeDeliver*` pattern), so a teardown row
can check that a stack's CloudFront log delivery is gone, and
`cloudwatch:GetMetricStatistics`, so a heartbeat row can read the `Honua/Operations`
`Heartbeat` metric. Neither has a resource scope: the delivery calls list every
delivery in the account, and the metric call returns datapoints for any metric
it names. `cloudwatch:ListMetrics` and `cloudwatch:GetMetricData` are not
granted. No other Config action is granted:
no resource configuration, compliance-by-resource, remediation or aggregator
reads, and no rule evaluation.

The lane may also call `cloudformation:DescribeStackResource` on gate stacks and
`ecs:ListClusters`, so a deploy watcher can find the stack's cluster. ListClusters
returns every cluster ARN in the account, including other workloads' cluster names,
but nothing about their contents.

The name fences and the `CreationTags` deny sit in the attached managed policy
`HonuaGateCloudFormationFences`, because the inline service policy is at its
10,240-character quota. Apply changes to it while no gate stack is running.

`CreationTags` covers the EC2 handlers that create a resource untagged and tag it
in a second call (`ec2:CreateTags`). That call is allowed on an unowned resource
only when it carries CloudFormation's reserved `aws:cloudformation:stack-name`
request tag for a `honua-gate-*` stack; a customer `HonuaGate=true` request tag
alone does not claim a resource.

The ACM certificate handler also requests an untagged certificate and tags it
afterwards, but with the stack tags only: a live gate update on 20 Nov was
denied because the reserved stack-name request tag was absent. Certificate ARNs
carry no name to fence, so `NamedCreationTags` allows `acm:AddTagsToCertificate`
on an unowned certificate when the request carries the stack's required
`HonuaGate=true` tag. The fence is attached to the CloudFormation service role
only, and a native certificate resource always requests a new certificate. No
gate principal (lane or reaper) can create change sets or import resources, so
a gate stack cannot import and tag a foreign certificate. The residual risk is
an account administrator who can pass the service role and create an import
change set; that principal already has broader rights than the fence protects. Deleting a certificate stays behind the ownership deny, so a
certificate whose create failed before CloudFormation tagged it has to be
deleted by an operator.

An HTTPS listener that names an ACM certificate makes ACM grant Elastic Load
Balancing use of the AWS-managed `aws/acm` key, authorized as the caller. That
key cannot carry `HonuaGate=true`, so a live gate update on 20 Nov failed on the
listener with "Access denied to certificate". The service role's ownership deny
therefore skips KMS calls that ACM makes for it (`kms:ViaService` matching
`acm.*`), mirroring the boundary's Secrets Manager exemption. ACM acts only on
certificates the role may already use, and workload roles keep the full fence.
Residual risk: the exemption covers any KMS call ACM makes for the role, on any
key. Today ACM uses only `aws/acm`, and the caller cannot choose the key; if ACM
ever accepts customer-managed keys, pin this to `kms:GrantIsForAWSResource` or
the `aws/acm` key ARN when the quota allows.

AWS does not expose this resource tag for every action. In particular, Route 53
record changes, other untaggable CloudFront resources (origin access identities,
key groups, public keys, KeyValueStores, real-time log configurations),
Application Auto Scaling
registrations, some Logs operations, EC2 association/route operations and service
resources without CloudFormation tag propagation may be denied even for gate
resources. These are **not** blanket write exceptions: a live install or cleanup
can fail closed, requiring a reviewed policy adjustment. Check each action in the
[AWS service authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/reference.html)
before expanding permissions. The global exceptions bypass only the region deny,
not ownership checks.

One write exception exists for WAF logging: log deliveries (`logs:*LogDelivery`)
have no resource ARN, so the service role, never workload roles, may create,
update and delete any delivery in the account. The account log resource policy
WAF would otherwise write stays denied; this root owns `honua-gate-waf-logs`,
which lets the log delivery service write only to `aws-waf-logs-honua-gate-*`
log groups.

CloudFront access logs (standard logging v2) follow the same shape, for the
service role only. The stack's `/aws/vendedlogs/honua/<stack>/edge-access`
group, its delivery source and destination (`honua-<stack GUID>-edge`) and the
delivery are in the first-tag name fence. CloudWatch Logs does not evaluate
resource tags on existing delivery resources: the first gate create was refused
`GetDeliveryDestination`, and its rollback `DeleteDeliveryDestination`, on a
destination created with `HonuaGate=true`. Delivery resources are therefore
outside the service role's ownership deny and fenced by
`HonuaGateCloudFormationFences` instead: creates and overwrites need the
`HonuaGate=true` request tag, a destination may target only a
`/aws/vendedlogs/honua/honua-gate-*` group, every call that names a source or
destination (including `CreateDelivery` and `UpdateDeliveryConfiguration`, but not tag removal) must
name a `honua-*-edge` one in this account, so a delivery cannot target another
account's destination, and destination policies stay denied. A source may
only name a gate distribution: CloudFront authorizes
`cloudfront:AllowVendedLogDeliveryForResource` on the distribution, which keeps
its ownership fence. Delivery IDs are random, so `GetDelivery` and
`DeleteDelivery` reach any delivery in the account; `UntagResource` is not
name-fenced on delivery resources; and a source or destination named like a
Launch Stack's but owned by a non-gate stack is not protected. The gate account
has no other delivery resources.
Workload roles stay behind the ownership deny. This root owns
`honua-gate-edge-access-logs`, which lets the delivery service write only to
`/aws/vendedlogs/honua/honua-gate-*` groups, and lanes may read those groups.
Two points rest on the next live create: the handlers send the stack tags in
the create request (a later `TagResource` alone fails the request-tag fence),
and the destination create does not call `PutDeliveryDestinationPolicy` when
the template sets no policy.

Creation APIs cannot prove ownership of a resource that does not yet exist.
They can allocate resources using existing dependencies (for example network
subnets, clusters or load balancer parents). Service-linked roles are account-wide
and outside workload permissions boundaries; service operations performed by
those roles are not fenced by these policies. S3 ownership uses names rather
than stack tags. Metadata access for the CloudFormation service role is account-wide. Workload
roles get metadata only for gate-tagged resources, except Cognito domain
description, which AWS does not support authorizing against a resource ARN.
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

### Launch Stack template uploads

The Launch Stack template is larger than the 51,200-byte inline `TemplateBody`
limit, so create and update calls pass an S3 `TemplateURL`. This root creates one
private bucket, `honua-gate-templates-<account>` in `us-east-1` (output
`template_bucket_name`): public access blocked, bucket-owner-enforced ownership,
versioning on, TLS required, and current and noncurrent versions expiring after
14 days. The lane role may only put and get objects under `templates/`; the
CloudFormation service role may only get them. The bucket name falls inside the
`honua-gate-*` namespace the service role manages, so the bucket policy denies
that role every action except `s3:GetObject` and denies workload roles
everything except `s3:GetObject` on `templates/*/console.zip`: a template cannot
rewrite, delete or re-policy the bucket it was launched from. That one read lets a
gate stack's Console installer fetch a bundle published with `--private-bucket`
(it retries with its own role when the anonymous read is refused). Objects use
S3-managed encryption (SSE-S3) rather than the
`aws/s3` KMS key, because shared-account mode denies `kms:Decrypt` on keys no
gate stack owns and the service role would be unable to read the template.
Templates are public product artifacts, not secrets. The lane grant is pinned to
this account (`aws:ResourceAccount`), so a squatted bucket of the same name in
another account cannot receive uploads. The bucket is versioned and has no
`force_destroy`: destroying this root requires deleting every object version and
delete marker first.

```bash
aws s3 cp honua-launch-stack.json "s3://$TEMPLATE_BUCKET/templates/<run-id>/honua-launch-stack.json"
aws cloudformation create-stack --stack-name honua-gate-<run-id> \
  --template-url "https://$TEMPLATE_BUCKET.s3.us-east-1.amazonaws.com/templates/<run-id>/honua-launch-stack.json" \
  --role-arn "$GATE_CLOUDFORMATION_ROLE" --tags Key=HonuaGate,Value=true ...
```

### Gate server images

Gate stacks need current server builds before any public image exists. This
root creates the private ECR repository `honua-gate/server` in `us-east-1`
(output `server_repository_uri`, sensitive): tags are immutable, images are
scanned on push, ECR-managed AES256 encryption (no KMS grant through the gate
fences, as for the template bucket) and only the newest 20 images are kept, so
a gate stack that outlives 20 newer pushes cannot replace its tasks.
The lane role may log in, push images and read their manifests in this repository only;
it cannot delete images, the repository or its policy. Workloads may also pull the
ECS-managed GuardDuty runtime agent from AWS's `aws-guardduty-agent-fargate`
repository, which has no gate tags. The boundary uses an account wildcard for it to
stay inside its quota; the Launch Stack execution role names AWS's account. The
wildcard would also exempt a repository with that name in this account, so do not
create one. A gate stack pulls by
digest: pass `ServerImageUri=<uri>@sha256:<digest>` and the repository ARN in
the template's private repository parameter, which grants the stack's
execution role the pull actions that the workload boundary already allows.
Launch Stack roles cannot write images. In shared-account mode the ownership
fence exempts only this Terraform-owned repository (it has no stack tag) and
registry login; image reads from every other repository still require gate
stack ownership. Whoever pushes must assume the lane role, so the pushing host's
role must be in `lane_principal_arns`.

```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${GATE_SERVER_REPOSITORY_URI%%/*}"
docker tag "$IMAGE" "$GATE_SERVER_REPOSITORY_URI:<new-tag>" && docker push "$GATE_SERVER_REPOSITORY_URI:<new-tag>"
aws ecr describe-images --region us-east-1 --repository-name honua-gate/server --image-ids imageTag=<new-tag> \
  --query 'imageDetails[0].imageDigest' --output text
```

The CloudFormation role may also pass gate roles to `events.amazonaws.com`, so a
stack's EventBridge rule can deliver findings through its own role instead of a
topic or key policy grant to the EventBridge service.

### Gate sign-in provider

This root creates the `honua-gate-idp` Cognito pool and hosted domain in
`us-east-1`. Only administrators can create users. Its confidential app client
uses the authorization-code flow with `openid`, `profile` and `email` scopes. The
`honua-gate-admin` user has a generated permanent password and belongs to the
`admin` group. A second user, `honua-gate-viewer`, belongs to no group: security
checks sign in with it to prove that a role-less session is denied. Its secret
(`honua-gate/idp/viewer`) carries no gate ownership tag, so the service role's
content-read fence and the workload boundary refuse it; its own resource policy
also denies every gate role, and the lane role has no Secrets Manager access.
Main hands it to the verifier. Never add `HonuaGate=true` to it. Invitations are suppressed; credentials are written directly to
Secrets Manager under `honua-gate/idp/` and never exposed as Terraform outputs.
Terraform state contains these credentials: keep the existing private encrypted
backend and restrict access to state and saved plans.

Cognito accepts only exact callback URLs, so gate callbacks are synced, not
wildcarded. After a gate stack reaches `CREATE_COMPLETE`, the gate lane invokes
`honua-gate-reaper-callbacks` with its lane role:

```bash
aws lambda invoke --region us-east-1 --function-name honua-gate-reaper-callbacks /dev/stdout
```

The function lists live top-level `honua-gate-*` stacks, takes each stack's
`OidcCallbackUrl` output when it is `https://<host>/admin/auth/callback` and
`<host>` is the domain of a CloudFront distribution that same stack created in
this account, and sets the client's callbacks to the static
`idp_callback_urls` plus those, newest first, within Cognito's 100-URL limit.
Every other client setting is copied unchanged, except that a
`DefaultRedirectURI` no longer in the list is dropped. Callbacks of deleted
stacks drop out on the next sync, so no main apply is needed per install. The
client changes only when the function runs: invoke it after deleting a stack
and after an apply that changes `idp_callback_urls`. `idp_callback_urls` (at most 20, exact HTTPS
URLs ending in `/admin/auth/callback`) stays as the permanent list; the
localhost default only permits bootstrap. Terraform ignores `callback_urls`
drift on the client, which the function owns.

The lane can invoke the function but has no Cognito permissions, and the
function registers only hosts of distributions owned by the gate stack itself. The function sits in the protected `honua-gate-reaper*`
namespace and runs as `HonuaGateCallbackSync`, outside `honua-gate-*`, so gate
stacks and the CloudFormation role cannot change its code or permissions.

The sensitive outputs `oidc_authority`, `oidc_client_id`,
`oidc_client_secret_arn` and `oidc_admin_secret_arn` provide the private runtime
configuration references. Set Launch Stack `OidcRoleClaimType=cognito:groups`
so membership in `admin` grants administrator access. The client secret value
is plaintext in its secret; the administrator secret is JSON with `username`
and `password`. Do not print either value or copy it to logs, issues or PRs.

This bootstrap provider remains managed by this root. Gate stacks may also
create their own sign-in provider. The `HonuaGateCloudFormation` role allows
explicit pool, client, domain, group and administrator-user lifecycle APIs,
membership changes, MFA configuration and resource tagging. The workload
boundary allows only `DescribeUserPool*` (pool, client and domain description),
because Launch Stack workloads only read their own pool client. Neither grants
user-data reads or authentication APIs. The lane role still operates through
CloudFormation.

In shared-account mode, pool allocation is the only Cognito write exempt from
ownership checks. Child creation, updates, deletion and tag changes require the
parent pool's `aws:cloudformation:stack-name` tag to match `honua-gate-*`.
`DescribeUserPoolDomain` is an account-wide metadata exception because AWS
provides no resource-level authorization for it. Other workload metadata requires
the pool ownership tag. Native CloudFormation resources must stabilize without
user-data reads; record exact live denials rather than broadening the policy.
See the [Cognito authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_cognito-idp.html).

Client-secret access is limited to the CloudFormation role and gate task
execution roles. Launch Stack containers fetch the secret through their ECS
**execution** role, which CloudFormation names
`<stack>-ExecutionRole-<suffix>`; the fence admits
`role/honua-gate-*-ExecutionRole-*` with `ArnNotLike`, so a new gate install
needs no approval or apply. Only `HonuaGateCloudFormation` can create
`honua-gate-*` roles, and only under the workload boundary. Keep gate stack
names short (about 30 characters) so the generated name keeps its
`ExecutionRole` part within IAM's 64-character role-name limit. The lane role
cannot create a stack whose name contains `ExecutionRole`, which would make
every generated role match. The pattern is a naming convention, not a
confidentiality boundary against the lane: a gate template can name any role
`…-ExecutionRole-…` explicitly, and CloudFormation itself is a reader. Treat the
gate client secret as available to anyone who can launch gate stacks.
`idp_task_execution_role_arns` still adds exact ARNs for a role named
differently. The task definition's own policy still needs to allow this
specific secret, as it already does for `OidcClientSecretArn`. Foreign secrets
keep their existing ownership denies. Only this exact client secret bypasses
those ownership checks; the gate policies deny all operations on it except a
single-secret read by an
approved principal, and deny every operation on the administrator secret.
The bootstrap operator retains Terraform secret lifecycle
access through its existing private credentials.

CloudFormation may remove targets and delete EventBridge rules whose names begin
`honua-gate-`, and delete KMS aliases with the same prefix, even when those
resources have no ownership tags. The service-role name fences deny those
operations on other names, and the nightly reaper rule remains protected.
[KMS requires authorization on both the alias and its backing key](https://docs.aws.amazon.com/kms/latest/developerguide/alias-access.html);
a separate deny requires the backing key to carry `HonuaGate=true`.
Workload roles retain the ownership-tag checks. This exception does not permit
alias updates or deletion of untagged keys, VPCs or internet gateways.

CloudFormation may also delete CloudTrail trails named `honua-protection-*` without
ownership tags. A failed create that never made its protection trail still tries
to delete the trail on rollback, and a trail that does not exist has no tags. A separate deny refuses
the delete when the trail carries another stack's CloudFormation stack-name tag, so
trails made by non-gate stacks stay protected. A hand-made, untagged trail with
that name is not protected. Gate stacks keep their trails on delete; main's
retained-resource cleanup removes them, because they count toward the account's
five-trails-per-region quota.

### Gate test Connections

A Launch Stack task role can assume customer Connection roles named
`honua-connection-*`. To test this on a gate install, deploy the quick-create
Connection role template as a `honua-gate-*` stack with a Connection ID that starts
with `gate-`. Bind the workload boundary into each role of that template at
publish time, as the gate publish step does for the Launch Stack roles; the
customer template does not change. The role is then named `honua-connection-gate-<id>`.

- The service role may create and manage `honua-connection-gate-*` roles, and only
  with the workload boundary attached. It cannot pass them to any service.
- The workload boundary allows `sts:AssumeRole` on `honua-connection-gate-*` roles
  only. The task role's own policy also requires the role's installation tag to
  match the stack. The boundary also refuses roles without `HonuaGate=true`, so
  only roles created by a gate stack can be assumed. The boundary carries this in
  the watchdog-parameter statement to stay inside its quota.
- Gate principals choose the installation tag value freely, so a gate stack could
  let another Launch Stack's task role assume a gate Connection role. Access then
  only reaches gate resources.
- The lane cannot assume these roles. Point the Connection at a gate-owned bucket:
  its KMS key carries `HonuaGate=true`, which the content-read fence requires.

The reaper's orphan role pass does not cover these roles; they are deleted with
their stack.

### Gate test domain

Launch Stack installs with `DomainNames` (custom viewer names, HTTPS from
CloudFront to the load balancer) need a real public zone. Set
`gate_test_domain` to a delegated test name, such as `gate.example.org`, in
the private tfvars. Use a domain kept for tests, never one under a production
domain: every gate stack controls every name in the zone, so a gate page could
set cookies for the parent domain, and anything that trusts the parent's
wildcard (CORS, CSP, OAuth redirect lists) would trust gate pages. The apply
creates one public Route 53 zone (about USD 0.50 a month) and outputs
`gate_test_zone_id` and `gate_test_name_servers`. With
`gate_test_parent_zone_id` naming a same-account parent zone, the apply also
writes the NS delegation; otherwise delegate from the parent by hand with the
name servers output. Empty `gate_test_domain` (the default) creates nothing.

Gate stacks install with names under the test domain and `HostedZoneId` set to
`gate_test_zone_id`, so CloudFormation writes the certificate validation and
alias records itself. Route 53 evaluates no resource tags, so the ownership deny
cannot tell a gate zone from any other one. The test zone's ARN is therefore
exempt from the service role's ownership and content-read denies only. Every
other hosted zone stays fenced, and workload roles stay fenced from the test
zone too. In the test zone the service role may only read and change ordinary
records: it cannot delete the zone, change its tags, comment, DNSSEC or query
logging, or write NS, SOA or DS records. Any gate stack may change any other
record in the zone, so keep nothing else in it. Stacks that fail to delete, and
ACM validation records, can leave records behind; the reaper does not clean the
zone. Clearing `gate_test_domain` deletes the zone with whatever records remain
(`force_destroy`).

A stack created without `DomainNames` and later updated to use them replaces
its VPC origin (`VpcOrigin` becomes `TlsVpcOrigin`). On one such stack (20 Nov)
the teardown deleted `TlsVpcOrigin` for its usual seven minutes and then failed
with `Access denied for operation 'AWS::CloudFront::VpcOrigin'`. Retries failed
the same way, and the origin was already gone. The denied call is unconfirmed
(#558; lanes cannot read CloudTrail). Two service-role denies can refuse it,
because a VPC origin never carries the `aws:cloudformation:stack-name` tag:
`DenyNonGateContentReads` covers `cloudfront:Get*`, and `DenyNonGateChanges`
refuses any change to an origin it finds without `HonuaGate=true`, including
one that no longer exists. When a VPC origin fails to delete with AccessDenied,
the lane runs `aws cloudfront get-vpc-origin --id <physical ID>`:

- `EntityNotFound` (the origin is gone): run `DeleteStack` again with
  `--retain-resources <logical ID>`. The origin was confirmed gone, so nothing
  is left behind.
- The origin exists: read its tags with `aws cloudfront list-tags-for-resource`.
  Without `HonuaGate=true` it is outside the fence, so main deletes it. With
  the tag, do not retry: send main the tags and the stack events.

### Orphan gate roles and keys

The nightly reaper also logs orphan IAM role and KMS key cleanup. This pass is
**dry-run by default** (`orphan_cleanup_dry_run = true`); expired-stack deletion
retains its existing behavior. Main reviews the log and applies Terraform with
`orphan_cleanup_dry_run = false` to enable orphan mutations. Lanes do not apply.

IAM role names must equal or begin with their `honua-gate-*` stack name followed
by `-`. Ownership uses the longest matching name in CloudFormation's stack
history. Roles outside that history are left for manual investigation. IAM and
KMS do not carry reserved CloudFormation ownership tags. Keys instead require
both an exact physical ID recorded as `AWS::KMS::Key` in a deleted gate stack's
resource history and the propagated `HonuaGate=true` tag. The reaper never scans
unrelated keys. Resources outside CloudFormation's retained deleted-stack
history (normally 90 days) are left for manual investigation. AWS-managed keys
and keys that have completed deletion are skipped.

A fresh stack lookup must report `DELETE_COMPLETE` or the specific stack-not-found
error. Every other status (including deletion in progress, failed deletion and
keep/protected live stacks) prevents orphan cleanup; lookup errors fail closed.
Role cleanup deletes inline policies, detaches managed policies, then deletes
the role. Managed policies themselves are retained. A role still in an instance
profile reports a cleanup failure; this pass does not detach live instance profiles.
Key cleanup schedules deletion with the seven-day minimum, skipping keys already
pending deletion. Per-resource failures are logged and fail the invocation after
other resources are checked. Offline tests do not prove live cleanup permission.

The same pass deletes unused gate ACM certificates. Every name on the certificate
must sit under `gate_test_domain` (empty skips the pass). ACM must report the
certificate not in use, it must be older than 24 hours, and no live `honua-gate-*`
stack may list it as a resource. The certificate must also carry the
`HonuaGate=true` stack tag, which the delete permission requires too. Certificates
that a denied rollback left untagged (20 Nov) need their exact IDs in
`temporary_orphan_certificate_ids` (private SSM tfvars, at most four), which grants
deletion of exactly those ARNs. Clear the list after the cleanup and apply again.
A certificate deleted or attached since the listing is skipped. The pass follows
`orphan_cleanup_dry_run`. Validation records in the test zone stay (see above).

The same invocation also plans retained `honua-protection-<stack guid>` trails whose log bucket name starts with `honua-gate-`, whose home region is the gate region, and which no live stack still owns or references. It then empties and deletes that bucket, including a leftover `honua-gate-*-protectiontrailbucket-*` bucket after its stack is gone. `honua-audit` trails and buckets are denied. Trails in another region, with any other name, or logging to any other bucket are left alone. The ownership check reads only live `honua-gate-*` stacks, which is the set this role can list. More than 50 of those fails the invocation before any deletion. A bucket still used by a trail that is not deleted is left in place. This pass follows `protection_trail_cleanup_dry_run` (default true). Main sets it to false and applies before invoking the reaper. Lanes do not apply. The CloudFormation service-role rollback of a trail that was never created is a separate fence.

## Authenticated release producers

`release_actions_role_arn` is the sensitive GitHub Actions entry point. Its only
permission is `sts:AssumeRole` for `HonuaGateLane`; producer jobs first assume
this entry role with OIDC, then assume the lane role. Main applies this root.
The existing account GitHub OIDC provider must already trust audience
`sts.amazonaws.com`; this root looks it up rather than creating another provider.

Before running a producer, Main configures the `honua-io/honua-release` repository:

1. Create the `gate` environment, restrict deployment branches to `trunk`, and
   leave required reviewers unset. Keep workflow changes under the repository's
   protected-branch review rules.
2. Keep the default GitHub OIDC subject format. Repository-wide subject
   customization also affects existing environments and is not needed here.
3. Set producer jobs to `environment: gate`, run them from `refs/heads/trunk`,
   and grant `id-token: write`. Use STS audience `sts.amazonaws.com` and pass the
   output role ARN through private configuration.

The trust uses `StringEquals` for the audience and the complete default subject
`repo:honua-io/honua-release:environment:gate`.
GitHub environment subjects do not include the branch ref: the `gate`
environment's deployment branch restriction enforces trunk-only access. Another
repository or environment, a subject without an environment, or a custom subject
with appended claims fails the IAM match. AWS checks the signed subject; GitHub
enforces environment deployment restrictions. A lane shell run does not provide
an authenticated producer receipt.

### Temporary orphan network cleanup

The lane role and its boundary can temporarily allow only `ec2:DeleteVpc`,
`ec2:DeleteInternetGateway` and `ec2:DetachInternetGateway` on exact network IDs.
`temporary_cleanup_vpc_ids` and `temporary_cleanup_gateway_ids` default to empty,
accept at most two IDs each and require shared-account mode. Supply the reviewed
orphan IDs through the private SSM tfvars; never commit actual IDs. This permission
does not change CloudFormation or workload ownership fences.

Main reviews the Terraform plan and applies it. Confirm that the plan grants only
the reviewed VPC and gateway ARNs in the gate account and us-east-1. Use the lane
role for cleanup, detach gateways before deleting them and delete the orphan VPCs.
Then clear both inputs in the private tfvars and apply the removal immediately.
Retain the removal plan and result with the private operational record. Leaving
an ID configured retains delete permission for that resource.

### Handler permission inventory

The [registry audit](tests/registry/README.md) compares the pinned Launch Stack
resource-handler permissions against the actual rendered CloudFormation role.
It also inventories inline custom-handler SDK calls separately. Its known-gap
regression can pass while the authorization sweep remains **NOT PASS**; use the
machine-readable report and installed create/update/teardown evidence before
claiming compatibility.

`temporary_cleanup_subnet_group_names` permits service-role deletion of exactly
one named gate-prefixed subnet group in shared mode, empty by default. While
configured, the separate name deny refuses deletion of every other subnet group,
including tagged groups. Remove the temporary entry after authorized cleanup.
