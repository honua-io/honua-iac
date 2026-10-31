# AWS short-lived execution identity

Creates the **infrastructure deployment role** for the governed Honua AWS lane
and records how it is separated from the other three permission surfaces.

This root creates no IAM user and no access key. There is no variable that makes
it create one. The certified path reaches this role through an existing SSO
session or an OIDC/workload identity, and every session is a short-lived STS
session bounded by `max_session_duration`.

## Four identities, four lanes

| Lane | Identity | Created by | May do |
|---|---|---|---|
| Backend access | `honua-terraform-backend` | `bootstrap/aws-terraform-oidc` (+ policy from `bootstrap/aws-tfstate`) | read/write exactly one state object and its lock |
| Infra deployment | `<name_prefix>-<environment>-deploy` | **this root** | provision the stack in one region |
| Task execution | `honua-*-execution` | `modules/aws-ecs` | pull images, fetch the task's secrets |
| App runtime | `honua-*-task` | `modules/aws-ecs` | what the application itself may call |

The deployment role is **explicitly denied**:

- every S3/DynamoDB operation against the state bucket and lock table, so a
  deployment session can never rewrite state lineage behind an approved plan;
- `iam:CreateUser`, `iam:CreateAccessKey`, `iam:CreateLoginProfile` and the rest
  of the long-lived-credential surface, so the certified path cannot mint a
  credential that outlives its session;
- `iam:PassRole` on itself and on the backend role, so it cannot run a task as
  the deployer or as the state reader.

It may pass the task execution and application runtime roles, by name prefix,
and only to the services for the approved topology: `ecs-tasks.amazonaws.com`
for ECS; `ec2`, `eks`, and `pods.eks` for EKS; `lambda`, `rds`, and
`scheduler` for Lambda, plus `batch` and `ecs-tasks` when `gp_batch` is on.

Resource preconditions fail the plan when the supplied role ARNs are not three
distinct roles, or when the selected `trust_mode` is missing its federation
inputs. These are hard plan gates, not advisory `check` warnings.

## Order of operations

```bash
# 1. state substrate (separate apply, never a side effect of terraform init)
terraform -chdir=bootstrap/aws-tfstate apply -var='bucket_name=...'

# 2. backend access role
terraform -chdir=bootstrap/aws-terraform-oidc apply

# 3. this root. topology is required. There is no full-grant default.
terraform -chdir=bootstrap/aws-exec-identity apply \
  -var='oidc_provider_arn=arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com' \
  -var='oidc_provider_url=https://token.actions.githubusercontent.com' \
  -var='oidc_subjects=["repo:honua-io/honua-iac:environment:prod"]' \
  -var='state_bucket_arn=arn:aws:s3:::honua-tfstate-prod' \
  -var='backend_access_role_arn=arn:aws:iam::123456789012:role/honua-terraform-backend' \
  -var='topology={compute="ecs",redis=true,custom_domain=false,waf=false,gp_batch=false}'

terraform -chdir=bootstrap/aws-exec-identity output -json execution_identity_contract
terraform -chdir=bootstrap/aws-exec-identity output -json deploy_identity_contract
```

For an SSO-based operator session set `trust_mode = "sso"` and list the
permission-set role ARNs in `trusted_principal_arns`. IAM user principals are
rejected by an input validation, not by convention.

## Wiring the two roles into one Terraform run

Assume this deployment role in the process credential before planning: an SSO
permission set, or a `credential_process` that calls STS. The exact-plan
receipt binds that caller. The backend block then assumes the backend-access
role, which must be a different role. Leave the AWS provider on the process
credential. A provider `assume_role` is invisible to the receipt, so the
apply would mutate as an identity the approval did not bind.

```hcl
terraform {
  backend "s3" {
    bucket       = "honua-tfstate-prod"
    key          = "honua/aws/prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true

    assume_role = {
      role_arn = "arn:aws:iam::123456789012:role/honua-terraform-backend"
    }
  }
}

provider "aws" {
  region = var.region
}
```

## Approval-receipt MAC key (`enable_approval_mac_key`, opt-in)

honua-devops approval receipts are HMAC-symmetric today: the verifier holds the
same key the issuer signs with, so **the verifier can forge any receipt it is
willing to accept**. That is fine for development and it is not evidence — and
the day-zero lane's premise is receipts-as-evidence (honua-devops#175, gating
honua-release#129).

The fix is not a different primitive but a different key custodian. Turning this
on creates a KMS key with `key_usage = GENERATE_VERIFY_MAC` and splits the
operation across two separately grantable actions:

| Principal | Action | Denied |
|---|---|---|
| Approval issuer (`approval_signer_role_names`) | `kms:GenerateMac` | `kms:VerifyMac` |
| Approval verifier (`approval_verifier_role_names`, default: the deployment role) | `kms:VerifyMac` | `kms:GenerateMac` |

A verifier that cannot call `GenerateMac` cannot produce a receipt it would
accept. That is what makes the receipt admissible.

**No export path.** A KMS key of this usage has no API that returns key material
— no `GetPublicKey`, no export, and the Encrypt/Decrypt/GenerateDataKey family is
invalid against it. "No principal exports the key" is a property of the key type,
not a policy this root has to defend.

**Enforced twice.** Each capability is granted by an identity policy *and* the
key policy explicitly `Deny`s each side the other's action. An explicit Deny
cannot be overridden by any Allow, so a later identity-policy edit cannot quietly
re-merge the two capabilities. Two **lifecycle preconditions** hard-fail the plan
when the signer list is empty or when a role appears on both sides — deliberately
not `check` blocks, which this root uses elsewhere to report separation facts but
which only emit a *warning* and let the apply proceed.

The signer is never defaulted. The issuer is a release-lane identity this root
does not create; silently defaulting it to the verifier would rebuild the exact
problem the key exists to remove.

```bash
# Release lane: see release-approval.tfvars.example and
# docs/devops/provision-approval-two-principal.md. Apply aws-release-cells first;
# it creates both roles this key policy names.
terraform -chdir=bootstrap/aws-exec-identity apply \
  -var='enable_approval_mac_key=true' \
  -var='approval_signer_role_names=["honua-release-approver"]' \
  -var='approval_verifier_role_names=["honua-release-cell-provision"]' \
  ...

# Wire BOTH the issuer (`honua-devops --issue-provision-approval`, run as the
# approver role) and the verifier (the honua-devops agent, run as the cell role).
# The issuer identity is the signer role name.
export HONUA_DEVOPS_PROVISION_APPROVAL_SIGNING_MODE=kms-mac
export HONUA_DEVOPS_PROVISION_APPROVAL_ISSUER_KEY_ARNS="$(
  terraform -chdir=bootstrap/aws-exec-identity output -raw approval_mac_issuer_key_arns)"
```

Rotation is operator-driven: KMS does not offer automatic rotation for HMAC keys,
and rotating invalidates receipts signed under the previous key, so it is a
deliberate re-issue rather than a background event.

`approval_mac_contract` records which principal holds which single action, where
the split is enforced, and that the key is not exportable. Like the identity
contract it carries no key material. A successful plan or validate implies no
live AWS qualification — a live `GenerateMac`/`VerifyMac` proof is honua-devops#175's
remaining work.

## Topology

`topology` is required. `compute` is `ecs`, `eks`, or `lambda`. `redis`,
`custom_domain`, `waf`, and `gp_batch` default to false. The deployment policy
is the union of `manifests/*.json` for that shape, assembled by
`infrastructure/terraform/validation/scripts/aws/generate-deploy-identity-manifests.py`.
Service actions are exact IAM actions, split so
ElastiCache, ACM, Route 53, WAFv2, and Batch are absent unless the matching
flag is on. `waf` permits associating an existing web ACL with an ECS load
balancer; it does not grant creation of web ACLs. `gp_batch` covers every Batch action `modules/aws-serverless`
uses, including custom-code batch. IAM administration stays in
`manifests/iam-workload.json` so it is not copied into every service statement.
The provider-resource and AWS service authorization references used for the
inventory are in [ACTION-REFERENCES.md](ACTION-REFERENCES.md). The manifest
check rejects wildcard action names.

The same denials as before stay on the role: state substrate, long-lived
credentials, passing the deployment or backend role, mutating the deployment
identity, and removing a permissions boundary. Trust is still short-lived
OIDC and SSO only. Name prefix, region, and the workload permissions boundary
are unchanged. Optional resources inside the nested VPC and EKS modules
(a Redshift subnet group, Karpenter's queue, a hybrid-node Roles Anywhere
profile) add only the API calls those resources make.

`deploy_identity_contract` is what a customer-facing agent shows: topology,
role ARN, actions by service, and what the role cannot do. It carries no
token or credential. It also lists the managed-policy ARNs and document sizes.
The regional actions are split across managed policies to fit IAM's document
size limit; each retains the region condition. The agent never needs IAM-admin.

A release cell (Lambda, Redis, GP batch, no custom domain, no WAF) is proved
by an administrator applying this root, then the release session assuming only
that role and applying `examples/aws-cert`. Do not put the role in a provider
`assume_role` block.

```bash
terraform -chdir=infrastructure/terraform/bootstrap/aws-exec-identity init
terraform -chdir=infrastructure/terraform/bootstrap/aws-exec-identity apply \
  -var='trust_mode=oidc' \
  -var='oidc_provider_arn=<REPLACE_WITH_OIDC_PROVIDER_ARN>' \
  -var='oidc_provider_url=https://token.actions.githubusercontent.com' \
  -var='oidc_subjects=["<REPLACE_WITH_EXACT_OIDC_SUBJECT>"]' \
  -var='state_bucket_arn=<REPLACE_WITH_STATE_BUCKET_ARN>' \
  -var='backend_access_role_arn=<REPLACE_WITH_BACKEND_ACCESS_ROLE_ARN>' \
  -var='topology={compute="lambda",redis=true,custom_domain=false,waf=false,gp_batch=true}'
```

## Evidence

`execution_identity_contract` and its digest carry account, partition, region,
issuer, audience, subjects, session bounds, the role references, and the
workload permissions boundary. They carry no token, no source credential, and
no session name. The `long_lived_credentials_created` output is a hard `false`
the release lane can assert on.

`workload_permissions_boundary_arn` is the ceiling for roles this identity
creates. Workload modules already accept `permissions_boundary_arn`. Pass this
output there. Without it, CreateRole and AttachRolePolicy are denied.
PassRole is limited to the topology's services and the workload role prefix.
IAM does not evaluate iam:PermissionsBoundary on PassRole, so that condition
is not on the allow. The boundary is a ceiling: the role's own policy still
scopes the grant. Service-linked roles are created separately and cannot
carry this boundary. Role administration is a second managed policy so neither
document exceeds the 6144-character managed-policy quota. This root attaches
no inline policy, so the 10240-character inline aggregate does not apply.

Terraform validation is the supported local check. A successful plan or validate
implies no live AWS qualification; that gate is honua-iac#118.

## State

Remote, at `bootstrap/aws-exec-identity/terraform.tfstate` (`backend.tf.example`; copy it to the gitignored `backend.tf`). Never keep this root's state on a workstation: the nightly bootstrap drift plan can only see roots whose state is in the bucket.
