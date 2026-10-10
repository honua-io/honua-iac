# AWS release-cell identities (operator staging)

This bootstrap separates provisioning, ECR mirroring, and teardown into three
GitHub OIDC roles. Each trusts a different, exact protected environment. It does
not update or replace `honua-release-cicd` automatically. An operator must review
the plan, configure environment protections and migrate the callers before the
new roles become active. Never attach PowerUserAccess to these roles.

The release promise is safe AWS certification of the GA ECS/Lambda substrates:
a disposable certification run must not modify or destroy standing certification
or demo resources. This is the pre-cut containment work in honua-iac#208.

## Plan and verify

Supply the existing GitHub OIDC provider and ECR mirror repository ARNs:

```sh
terraform init -backend=false
terraform plan -out=cell-identities.tfplan \
  -var='oidc_provider_arn=arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com' \
  -var='mirror_repository_arn=arn:aws:ecr:us-east-1:ACCOUNT:repository/honua-server'
terraform show cell-identities.tfplan
```

The plan creates three roles, three inline grant policies, one shared guardrail policy,
three guardrail attachments, and one workload boundary.
It grants no access to standing state, budgets, account controls or identity
providers. It does not create service-linked roles. Operator-created service
linked roles and backend identities are separate prerequisites. The cell role
cannot assume another role; each job must obtain its own web identity session.

```sh
terraform test -json -verbose > /tmp/cell-policy-tests.jsonl
python3 ../../validation/scripts/aws/verify-release-cell-policies.py \
  /tmp/cell-policy-tests.jsonl --receipt /tmp/cell-policy-decisions.json
```

The second command calls IAM SimulateCustomPolicy with the actual rendered
policies and independent allow/deny fixtures. It never deletes or changes a cloud
resource. Its caller needs `iam:SimulateCustomPolicy`. Simulator results establish
policy decisions for the supplied context, not end-to-end service authorization.
CloudWatch cases use log-group authorization ARNs ending in `:*`; the simulator
returns a false implicit deny for concrete log-stream ARNs even with an isolated
allow-all policy. The verifier additionally checks exact ECS/Lambda/Batch stream
ARNs against the rendered resource ceiling and rejects an unrelated stream.

## Caller migration (required before activation)

- Provision, mirror and reap jobs use their corresponding `role_arns` output and
  protected GitHub environment. Do not share a single unrestricted trunk subject.
- Cell resources carry `Owner=release-cell`, a nonempty `ValidationRunId` in the
  reaper format `gha-RUN_ID-aws-STACK`, and an ephemeral
  Environment. Names remain in `honuar*`, `honuan*`, or `honuaeks*` namespaces.
- Pass `permissions_boundary_arn` to both `examples/aws` and
  `examples/aws-serverless`. Every workload role these modules create retains the boundary,
  including Batch task, custom-code and scheduled-event roles. Bounded Batch
  deployments must set `use_batch_service_linked_role=true` and use an
  operator-created AWSServiceRoleForBatch infrastructure role. Legacy roles in these
  namespaces must be inventoried and bounded by the operator before PassRole is
  enabled; a name alone does not establish that an old role is safe.
  `enable_workload_role_passing` defaults to false and only the operator can
  activate it after that inventory.
- Invoke the reaper with `--owner-tag release-cell`; it reads the same
  `ValidationRunId` as the IAM contract.
- Read-only discovery is account-wide. Mutation grants require cell tags and,
  where a service exposes names, the cell namespace. APIs that cannot supply the
  relevant tag context fail closed. Do not remove those conditions to make an
  apply succeed. Capture the actual denied API and qualify a narrow alternative.
- This initial policy intentionally does not authorize EKS provisioning  . That path still requires a scoped
  service-specific policy and a live positive lifecycle receipt before replacing
  the existing six-cell workflow role. The runtime allowlist supports exact-model Bedrock inputs, namespaced Batch
  submission and event invocation; all need live qualification for #207. The workload boundary excludes IAM and role chaining even if a task receives a broad inline policy.

For Lambda VPC networking, an operator can add exact `workload_vpc_arns` after
creating and tagging the ephemeral VPC. Terraform rejects standing/demo,
unowned, wrong-account and wrong-region VPCs. ENI operations require that exact
VPC context on the subnet/security-group authorization checks for creation
and on existing ENIs for mutations; an empty allowlist grants none. This two-stage setup and the
service-linked Batch role must be qualified with real deployments before use.

For StudioAi, set `runtime_bedrock_model_arns` to the exact model/profile ARNs
used by the ECS/Lambda module from #207, including each inference-profile
destination. An empty set grants no invocation; wildcard ARNs are rejected.
Batch submission is limited to namespaced queues/job definitions and scheduler
invocation to namespaced Lambda handlers. These are permissions ceilings: each
workload role must still carry its own scoped grants. Standing/region denies
continue to apply. The native fixture checks the IAM policy size with networking
and the four certification model/profile ARNs enabled together.

For a Redis-on ECS or Lambda cell, set
`runtime_operation_key_ring_certificate_secret_arns` to the exact ARN of the
operator-owned key-ring certificate secret that the cells pass as
`operation_key_ring_certificate_secret_arn` (and
`runtime_operation_key_ring_certificate_kms_key_arns` for a customer-managed
key). That secret deliberately lives outside the cell namespaces so it outlives
every cell and the reaper never touches it; without this input the boundary
denies the read and the Redis-on server never becomes ready. Wildcards are
rejected and an empty set grants nothing.

## Standing stack and alerts

`examples/aws-cert` fixes `Owner=release-standing`, `Lifecycle=standing` and
`Environment=cert` after caller tags and applies them as provider default tags to
all taggable resources. IAM explicitly denies standing/demo resources, including
EC2's service-specific tag keys; protected S3/ECR names also cover actions without
a resource-tag context. The reaper independently excludes protected tags even
when a disposable owner/run/expiry is accidentally also present.

Actual-spend alerts are absolute $100 and $200 thresholds; the forecast alert
remains. After the operator applies the standing-stack plan, verify both budgets
notifications and the SNS subscriptions:

```sh
aws budgets describe-notifications-for-budget --account-id ACCOUNT \
  --budget-name honua-cert-cert-monthly
aws sns list-subscriptions-by-topic --region us-east-1 --topic-arn TOPIC_ARN
```

An email recipient must confirm their subscription. Empty results or
`PendingConfirmation` are not acceptance evidence. Terraform cannot confirm an
email subscription on the recipient's behalf.

## Qualification status, 2026-09-29

After merging the #207 inputs from trunk, all 47 ECS and 32 serverless native
module tests pass together. The bootstrap has five native policy tests and
98 passing AWS IAM decisions with independently specified expectations.

Read-only inspection of account `585192672263` found the existing $200 budget
with actual 50%, 80%, 100% notifications, 73 `Environment=cert` tagged resources
but no `Lifecycle=standing`, no SNS subscriptions in us-east-1, and the existing
`honua-release-cicd` role still attached to PowerUserAccess. No apply was performed.
The new role policy simulator and hermetic reaper tests do not close the live
activation, six-cell positive lifecycle, standing-tag apply, or confirmed-alert
criteria. These remain pre-cut work under #208, not candidate-dependent releases.

## Provision-approval approver

`approval.tf` adds `honua-release-approver`, a fourth OIDC role trusted only by
the `terraform-live-approval` environment of `honua-io/honua-release`. It is
denied every action except `kms:GenerateMac`; the provision lane is denied
`kms:GenerateMac`. The key and the scoped Allows come from
`bootstrap/aws-exec-identity` (`enable_approval_mac_key`), applied after this
root. See
[docs/devops/provision-approval-two-principal.md](../../../../docs/devops/provision-approval-two-principal.md).
