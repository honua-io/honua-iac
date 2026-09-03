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
and only to `ecs-tasks.amazonaws.com`.

Resource preconditions fail the plan when the supplied role ARNs are not three
distinct roles, or when the selected `trust_mode` is missing its federation
inputs. These are hard plan gates, not advisory `check` warnings.

## Order of operations

```bash
# 1. state substrate (separate apply, never a side effect of terraform init)
terraform -chdir=bootstrap/aws-tfstate apply -var='bucket_name=...'

# 2. backend access role
terraform -chdir=bootstrap/aws-terraform-oidc apply

# 3. this root
terraform -chdir=bootstrap/aws-exec-identity apply \
  -var='oidc_provider_arn=arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com' \
  -var='oidc_provider_url=https://token.actions.githubusercontent.com' \
  -var='oidc_subjects=["repo:honua-io/honua-iac:environment:prod"]' \
  -var='state_bucket_arn=arn:aws:s3:::honua-tfstate-prod' \
  -var='backend_access_role_arn=arn:aws:iam::123456789012:role/honua-terraform-backend'

terraform -chdir=bootstrap/aws-exec-identity output -json execution_identity_contract
```

For an SSO-based operator session set `trust_mode = "sso"` and list the
permission-set role ARNs in `trusted_principal_arns`. IAM user principals are
rejected by an input validation, not by convention.

## Wiring the two roles into one Terraform run

Terraform holds both roles at once without either inheriting the other's
permissions: the backend block assumes the backend role, the provider assumes
the deployment role.

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

  assume_role {
    role_arn = "arn:aws:iam::123456789012:role/honua-prod-deploy"
  }
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
terraform -chdir=bootstrap/aws-exec-identity apply \
  -var='enable_approval_mac_key=true' \
  -var='approval_signer_role_names=["honua-release-approver"]' \
  ...

# Wire the verifier (the honua-devops agent):
export HONUA_DEVOPS_PROVISION_APPROVAL_SIGNING_MODE=kms-mac
export HONUA_DEVOPS_PROVISION_APPROVAL_ISSUER_KEY_ARNS="release://approver=$(
  terraform -chdir=bootstrap/aws-exec-identity output -raw approval_mac_key_arn)"
```

Rotation is operator-driven: KMS does not offer automatic rotation for HMAC keys,
and rotating invalidates receipts signed under the previous key, so it is a
deliberate re-issue rather than a background event.

`approval_mac_contract` records which principal holds which single action, where
the split is enforced, and that the key is not exportable. Like the identity
contract it carries no key material. A successful plan or validate implies no
live AWS qualification — a live `GenerateMac`/`VerifyMac` proof is honua-devops#175's
remaining work.

## Evidence

`execution_identity_contract` and its digest carry account, partition, region,
issuer, audience, subjects, session bounds, and the four role references. They
carry no token, no source credential, and no session name. The
`long_lived_credentials_created` output is a hard `false` the release lane can
assert on.

Terraform validation is the supported local check. A successful plan or validate
implies no live AWS qualification; that gate is honua-iac#118.
