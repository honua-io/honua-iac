# Launch Stack handler permission inventory

This offline inventory compares native CloudFormation handler permissions with the
actual gate CloudFormation role policies rendered by Terraform's mock provider.
It is an authorization model, not an AWS IAM simulator or an installed-stack pass.

The pinned source contains 214 resources: 74 native types and eight custom types.
It has no nested stacks. The capture tool recursively visits nested templates when
explicit source mappings are supplied, and rejects missing mappings, cycles and
unexpanded AWS::Include transforms.

`launch-stack.json` records the immutable source commit, template SHA256, registry
archive SHA256, native handler permissions and the relevant AWS authorization
metadata. Resource logical IDs and custom type names are anonymized. Only feature
switches needed by the audit survive projection; inline handler code, runtime
policy documents, deployment inputs and identifiers are excluded. Custom handlers
have a conservative static SDK-call inventory, not execution-role authorization.

## Reproduce offline

Python 3.11 or newer and PyYAML 6.0.3 are required; Terraform uses the root's pinned provider lock.
Run these commands from the repository root in an approved build environment:

```bash
root=infrastructure/terraform/bootstrap/aws-gate-runtime
python3 -m venv /tmp/gate-registry-test
/tmp/gate-registry-test/bin/pip install PyYAML==6.0.3
source /tmp/gate-registry-test/bin/activate
python3 -m unittest discover -s "$root/tests/registry" -p 'test_*.py'
terraform -chdir="$root" init -backend=false -input=false
terraform -chdir="$root" test -filter=tests/controls.tftest.hcl -json -verbose > /tmp/gate-plan.jsonl
python3 "$root/tests/registry/verify_tags.py" /tmp/gate-plan.jsonl
python3 "$root/tests/registry/audit.py" /tmp/gate-plan.jsonl --report /tmp/gate-sweep.json
```

The last command exits nonzero while any permission is unresolved. The JSON report
contains every resource, handler, action, modeled request and decision. CI uses
`--expected-gaps "$root/tests/registry/expected-gaps.json"` to detect inventory
changes while preserving the unresolved list. Matching that baseline is a
regression check; it explicitly reports **authorization sweep NOT PASS**. Never
use baseline success as evidence that installation or teardown is authorized.

The captured inventory currently produces 4,876 checks: 3,970 Allow, 409
NotApplicable and 497 unresolved. These include 197 calls whose complete
multi-resource mapping is unverified, 20 unresolved service-linked-role identities,
87 unresolved PassRole identities, 31 custom runtime calls with unverified execution
policies, seven unknown actions, and 155 explicit or implicit policy denies. The inventory includes
all template resources rather than selecting only one deployment's conditions.

## What the model covers

Native create, read/stabilize, update, delete and separate tagging permissions
come from the [CloudFormation resource schemas](https://schema.cloudformation.us-east-1.amazonaws.com/CloudformationSchema.zip).
Action resource formats and supported condition keys come from the
[AWS service authorization metadata](https://servicereference.us-east-1.amazonaws.com/v1/service-list.json).
Known registry/API spelling differences have explicit mappings in `actions.py`;
unrecognized actions remain unresolved. Optional permissions are excluded only
when the relevant template property is absent or a literal value cannot activate
that feature. Unresolved intrinsic values conservatively activate features.

Requests use a synthetic account, us-east-1, gate-prefixed names and ownership
context only when the authorization metadata supports the relevant condition key.
Create-time allocations start without resource ownership tags. IAM role creation
does not assume a permissions boundary: an absent property supplies no condition
context, and an unresolved boundary expression stays unresolved. Service-linked
role identities also stay unresolved. Parent-dependent and multi-resource calls
require explicit expansion rules; unmodeled multi-resource calls stay unresolved
rather than selecting one authorization resource. Missing or
ambiguous mappings fail visibly. Explicit tagging targets cover the native
resource types in `tag_targets.py`; standalone EC2 first tagging and tagging
authorized by its creation API must both pass. Mixed EC2 creation calls check the
new child without ownership tags and the existing parent with ownership. Native
S3 bucket endpoints select bucket or object ARNs explicitly. PassRole identities
are modeled for Lambda functions and ECS task definitions; other providers stay
unresolved. The evaluator supports only the condition
operators emitted by this root and rejects unsupported operators.

These are gate-owned synthetic requests. The model does not resolve real imported
resource IDs, every CloudFormation intrinsic, service control policies, session
policies, resource policies, service-linked-role execution or SDK control flow.
It does not evaluate the custom handlers' execution-role policies or workload
boundary intersection. Their calls remain `UnverifiedRuntimePolicy` even when the
CloudFormation role would allow the same action. Dynamic SDK clients and calls
outside the recognized inline boto3 forms require manual inspection.

## Unresolved operations

The machine-readable baseline is the complete current list. Important categories
include imported hosted-zone writes and record reads; untaggable account-wide
CloudFront, ECS and Logs operations; sensitive Cognito client-secret and user
reads; IAM boundary removal; and content reads deliberately restricted by the
shared-account fences. Resource schemas can include permissions for provider
branches that this static model cannot prove unreachable. A denied row therefore
needs provider-path or installed evidence before changing the policy.

Do not fix these rows by broadly exempting a service from ownership or content
fences. For example, `ecs:DeregisterTaskDefinition` has no resource-level scope in
its [authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonelasticcontainerservice.html),
so a task-family ARN alone cannot enforce the existing ownership fence. RDS
create-time tagging is separately repaired with both a gate ARN fence and the
HonuaGate request tag; its negative tests cover foreign names, accounts, regions
and missing or false request tags.

## Refresh the snapshot

Capture requires authorized access to the source checkout and downloads public
AWS metadata. It does not call AWS APIs or use cloud credentials:

```bash
python3 "$root/tests/registry/snapshot.py" /path/to/source-checkout \
  IMMUTABLE_COMMIT /tmp/launch-stack.json
# For each nested stack, also supply:
# --nested-template 'parent/path.yaml#LogicalId=nested/path.yaml'
```

Inspect the projected output before replacing `launch-stack.json`. Review schema,
feature-projection and authorization changes before updating the gap baseline;
never regenerate it merely to clear a failing check. Retain the source and AWS
metadata hashes so an inventory change can be distinguished from a policy change.
The rendered-policy tagging verifier exercises first tagging, existing ownership,
foreign names/accounts/regions, missing or false request tags, cross-API targets
and the unchanged workload boundary. Installed acceptance still requires applied IaC and a normal-role install and
teardown against the pinned workload.
