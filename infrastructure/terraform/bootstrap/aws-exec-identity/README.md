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

`check` blocks fail the plan when the supplied role ARNs are not three distinct
roles, or when the selected `trust_mode` is missing its federation inputs.

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

## Evidence

`execution_identity_contract` and its digest carry account, partition, region,
issuer, audience, subjects, session bounds, and the four role references. They
carry no token, no source credential, and no session name. The
`long_lived_credentials_created` output is a hard `false` the release lane can
assert on.

Terraform validation is the supported local check. A successful plan or validate
implies no live AWS qualification; that gate is honua-iac#118.
