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
they match that prefix. Pre-existing buckets with the gate prefix are therefore a
name-collision risk: main must ensure the prefix is reserved exclusively for gate
stacks before granting access.

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
create from overwrite, so those calls are limited to `honua-gate-*` names.
`events:*` on `honua-gate-nightly-reaper` and `budgets:*` on
`honua-gate-shared-monthly` are denied even though those names match the prefix.

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

- **Creation tags.** EC2 and RDS handlers create a resource and then tag it
  (`ec2:CreateTags`, `rds:AddTagsToResource`) while it has no tag yet, so the
  ownership deny refused the tag call and left an untagged resource that the gate
  could no longer delete. For those two APIs only, the ownership deny is replaced
  by a `CreationTags` deny that also spares a request carrying the reserved
  `aws:cloudformation:stack-name` request tag with a `honua-gate-*` value. Only
  CloudFormation can send `aws:`-prefixed tags, and the lane role cannot create
  change sets, so it cannot import a foreign resource into a gate stack. Create,
  restore and copy calls carry the same request tag, so no other statement may
  trust it: a restore from a foreign snapshot stays denied. `HonuaGate=true` as a
  request tag spares nothing, because any principal can send it.
- **Untaggable CloudFront types.** Cache, origin-request and response-headers
  policies and origin access controls cannot carry tags, their create calls take no
  resource and their other calls name a random ID. The service role may create,
  read, update and delete any of them in the account; CloudFront refuses to delete
  a policy still attached to a distribution. CloudFormation only changes resources
  its stack owns, but a third-party or private registry resource type runs with the
  service role's credentials; keep such types deactivated in the shared account.
  CloudFront functions are fenced by name (`function/honua-gate-*`): set the Launch
  Stack `NamePrefix` to `honua-gate`, or the function is created and then orphaned.

`HonuaGateLane` can inspect EC2 resources with `ec2:Describe*` and read KMS key
ownership tags with `kms:ListResourceTags`. Both the lane policy and its permissions
boundary include these reads. KMS reads name only keys in the configured gate
account and `us-east-1`; the existing region deny also limits EC2 inspection.

The name fences and the `CreationTags` deny sit in the attached managed policy
`HonuaGateCloudFormationFences`, because the inline service policy is at its
10,240-character quota. Apply changes to it while no gate stack is running.

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
it cannot delete images, the repository or its policy. A gate stack pulls by
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
uses the authorization-code flow with `openid` and `profile` scopes. The
`honua-gate-admin` user has a generated permanent password and belongs to the
`admin` group. Invitations are suppressed; credentials are written directly to
Secrets Manager under `honua-gate/idp/` and never exposed as Terraform outputs.
Terraform state contains these credentials: keep the existing private encrypted
backend and restrict access to state and saved plans.

Main supplies `idp_callback_urls` privately as exact HTTPS URLs ending in
`/admin/auth/callback`. Cognito does not accept wildcard callbacks. The initial
localhost callback only permits bootstrap before the stack has a hostname;
it does not enable sign-in to the installed stack. After CloudFront assigns a
hostname, main updates the callback list with that stack's exact public callback
and applies this root before testing sign-in. Remove callbacks when deleting
stacks. The gate lane cannot update the provider directly.

The sensitive outputs `oidc_authority`, `oidc_client_id`,
`oidc_client_secret_arn` and `oidc_admin_secret_arn` provide the private runtime
configuration references. Set Launch Stack `OidcRoleClaimType=cognito:groups`
so membership in `admin` grants administrator access. The client secret value
is plaintext in its secret; the administrator secret is JSON with `username`
and `password`. Do not print either value or copy it to logs, issues or PRs.

This bootstrap provider remains managed by this root. Gate stacks may also
create their own sign-in provider. The workload boundary and
`HonuaGateCloudFormation` role allow explicit pool, client, domain, group and
administrator-user lifecycle APIs, membership changes, MFA configuration and
resource tagging. They grant no user-data reads or authentication APIs. The lane
role still operates through CloudFormation.

In shared-account mode, pool allocation is the only Cognito write exempt from
ownership checks. Child creation, updates, deletion and tag changes require the
parent pool's `aws:cloudformation:stack-name` tag to match `honua-gate-*`.
`DescribeUserPoolDomain` is an account-wide metadata exception because AWS
provides no resource-level authorization for it. Other workload metadata requires
the pool ownership tag. Native CloudFormation resources must stabilize without
user-data reads; record exact live denials rather than broadening the policy.
See the [Cognito authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_cognito-idp.html).

Client-secret access defaults to the CloudFormation role only. Existing Launch
Stack containers fetch the secret through their ECS **execution** role. Main
must approve and set `idp_task_execution_role_arns` to the exact installed
execution-role ARN before launching containers; an empty list deliberately
blocks that fetch. The task definition's own policy still needs to allow this
specific secret, as it already does for `OidcClientSecretArn`. Do not grant the
application task role or lane role access. Foreign secrets keep their existing
ownership denies. Only this exact client secret bypasses those ownership checks;
the gate policies deny all operations on it except a single-secret read by an
approved principal. The bootstrap operator retains Terraform secret lifecycle
access through its existing private credentials.

CloudFormation may remove targets and delete EventBridge rules whose names begin
`honua-gate-`, and delete KMS aliases with the same prefix, even when those
resources have no ownership tags. The service-role name fences deny those
operations on other names, and the nightly reaper rule remains protected.
[KMS requires authorization on both the alias and its backing key](https://docs.aws.amazon.com/kms/latest/developerguide/alias-access.html);
a separate deny requires the backing key to carry `HonuaGate=true`.
Workload roles retain the ownership-tag checks. This exception does not permit
alias updates or deletion of untagged keys, VPCs or internet gateways.

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
