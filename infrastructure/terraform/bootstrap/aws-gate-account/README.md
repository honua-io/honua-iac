# Gate test account

Main applies this two-stage bootstrap. It creates an isolated organization member
for live Launch Stack gate tests, restricts regional operations to `us-east-1`,
and gives lanes access only to `honua-gate-*` CloudFormation stacks through one
service role. IAM, Route 53 and CloudFront are global-service exceptions.

The monthly linked-account budget is USD 300. At 80 percent actual cost it sends
an email; at 100 percent it automatically attaches a read-and-cleanup-only SCP.
This blocks new provisioning, including new stacks and stack updates. It is not
a guaranteed billing ceiling: [AWS budget data is delayed](https://docs.aws.amazon.com/cost-management/latest/userguide/bcm-lite-use-budget.html),
existing resources continue accruing cost, and SCPs do not constrain service-linked
roles. Main must monitor spend and remove expensive resources promptly. Allow a
policy-attachment slot for the budget fence. Review the fence before resetting
its budget action; a monthly rollover does not substitute for cleanup.

## Private configuration and state

Use Terraform 1.10 or later. Main must have organization management credentials,
all-features mode, SCPs enabled at the parent, inherited FullAWSAccess, permission
to create a member account, and an unused account contact address. Account creation
can require manual AWS verification. No credentials or identifiers belong in PRs,
workflow artifacts or screenshots.

Store two JSON objects as SSM SecureString parameters in `us-east-1`, using the
private parameter paths selected by main. The account object contains
`management_account_id`, `parent_id`, `account_email`, `budget_alert_email`.
The runtime object contains `member_account_id` and `lane_principal_arns` (a
nonempty array of exact trusted IAM role ARNs). Populate the second object after
the member exists. Do not grant lanes access to the management-stage inputs,
bootstrap credentials or Terraform state. The loader needs SSM GetParameter and,
for a customer-managed key, KMS Decrypt; it never prints the decrypted values.

From this directory, load the first object using a private environment variable:

```bash
python3 ../aws-gate-tools/gate_tools.py load-config "$GATE_ACCOUNT_PARAMETER" terraform.tfvars.json
cp backend.tf.example backend.tf
terraform init
terraform plan -out=gate.tfplan
```

Fill the backend copy with the existing encrypted state bucket and its distinct
backend access role before initializing. State keys are separate for the two
stages. Keep state in the existing management-owned backend, not in this new
member. Plans, state, local backend copies and tfvars contain sensitive values;
keep them private. The roots are registered as unapplied in the drift inventory.
Main must switch them to applied/operator entries with private SSM inputs when
applying, so the nightly inventory does not report an unexpected state object.

Main reviews and applies the saved account plan, then privately transfers the
sensitive `member_account_id` output to the runtime SSM object. Assume the new
member's `HonuaGateBootstrap` role from the organization management account.
In `../aws-gate-runtime`, repeat the load/init/plan steps with
`GATE_RUNTIME_PARAMETER`. The provider checks the configured account identifier
in each stage. Main reviews and applies the runtime plan. This PR does not apply
either stage. The account has deletion protection in Terraform and is never
closed on destroy; account retirement is a separate founder operation.

## Lane use

Assume the sensitive runtime `lane_role_arn` output using one of the trusted
roles. Supply the sensitive `cloudformation_role_arn` output explicitly as
`RoleARN` on every create, update and delete. Stack names must start with
`honua-gate-`. Direct resource creation, change sets and nested stacks are not
part of this lane interface.

Launch templates create IAM roles, so each role must carry the runtime
`workload_boundary_arn` as its PermissionsBoundary. Prepare a JSON CloudFormation
template before deployment (convert source YAML to JSON with your existing
CloudFormation tooling if necessary):

```bash
python3 ../aws-gate-tools/gate_tools.py bind-template "$GATE_SOURCE_JSON" \
  --boundary-arn "$GATE_WORKLOAD_BOUNDARY_ARN" --output "$GATE_BOUND_TEMPLATE"
```

The helper preserves resource properties, inserts the boundary, and rejects
transforms, nested stacks and explicit IAM role names outside `honua-gate-*`.
Unnamed roles inherit the gate stack name in their generated names. The service
role enforces the boundary independently of this helper. Workloads and templates
cannot change bootstrap IAM controls, the reaper function or its logs. Resource
permissions cover the Launch Stack's service families within this disposable
account; they are not suitable as a production deployment identity.

## Nightly cleanup and live acceptance

The reaper runs at 03:00 UTC. It deletes top-level `honua-gate-*` stacks whose
creation time is more than 24 hours old, after refreshing their current details.
The presence of a `keep` tag, regardless of value, preserves a stack. Termination
protection also preserves it. Deleted and deleting stacks are skipped. A daily
schedule means an unprotected stack can live almost 48 hours. Main owns retained
stacks and their spend. The reaper uses the same CloudFormation service role.

Delete requests are asynchronous. Retained resources, nonempty buckets and
service deletion prerequisites can leave DELETE_FAILED stacks; inspect stack
events and clear them explicitly. Budget restrictions can also block teardown
updates needed by some services. A failed API request is logged and makes the
Lambda invocation fail after the other candidates have been attempted. Monitor
Lambda Errors and stack DELETE_FAILED states; inspect the function's 14-day log
group. A successful invocation counts accepted deletion requests, not completed
deletions.

Before recording a live gate pass, main must verify: member isolation and region
denial; allowed gate stack create/update/delete; denial of other names and wrong
service roles; workload role boundary enforcement; reaper preservation of keep
and protected stacks and deletion of an aged disposable stack; and a controlled
budget-action execution that attaches the fence and denies new provisioning.
Verify cleanup remains possible, then reset the test action privately. Offline
tests validate policy wiring and cleanup decisions, not AWS enforcement or spend.
