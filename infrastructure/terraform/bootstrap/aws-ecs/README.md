# AWS ECS/Fargate Terraform Service Account (local-only, unsupported for release)

> [!WARNING]
> **LOCAL-ONLY. UNSUPPORTED FOR RELEASE OR CERTIFICATION.**
>
> This root creates a **long-lived IAM user** (and, if you ask for it, a
> long-lived access key). The governed Honua AWS lane refuses long-lived
> credentials outright: `scripts/terraform-exact-plan.sh` and
> `scripts/terraform-exact-apply.sh` fail closed with
> `REFUSED[long-lived-credential-refused]` when the caller is an IAM user.
>
> Use it only for a disposable local development account you own and can
> delete. For anything shared, long-lived, or release-bound use
> [`bootstrap/aws-exec-identity`](../aws-exec-identity/README.md), which
> federates an existing SSO or OIDC identity into a short-lived STS session and
> creates no IAM user and no access key.
>
> The posture is machine-readable: this root's `supported_for_release` output is
> a hard `false`, its `release_posture` output names the certified alternative,
> and every principal it creates is tagged
> `HonuaReleasePosture=unsupported-local-only`.

Creates a least-privilege IAM user and policy for running the `modules/aws-ecs` Terraform module.

## Usage
```bash
terraform init
terraform apply
```

## IAM scope

The user can manage IAM only for the stack it deploys:

- Roles and customer-managed policies are confined to
  `role/<workload_name_prefix>*` and `policy/<workload_name_prefix>*`. Set
  `workload_name_prefix` to the example's `name_prefix` (`honuaecs` for `examples/aws`; the
  default `honua` covers every shipped example).
- `iam:CreateRole`, and any later attach/detach/put/delete of a role policy,
  requires the role to carry this root's workload permissions boundary
  (`iam:PermissionsBoundary` condition). The boundary
  (`<user_name>-workload-boundary`, output `workload_permissions_boundary_arn`)
  allows service actions but never IAM, Organizations, Account or role
  assumption. Pass it as `permissions_boundary_arn` to `examples/aws`.
- `iam:PassRole` is allowed only for prefix roles and only to `ecs-tasks.amazonaws.com`.
- The separation denials from `bootstrap/aws-exec-identity` are ported:
  `DenyLongLivedCredentials`, `DenyPassingPrivilegedRoles` and
  `DenyDeploymentIdentityMutation` (the user's own `-policy` and `-iam`
  policies, the boundary, and the governed `*-deploy`, `*-gha` and
  `honua-terraform-backend*` roles, plus `protected_role_arns`), along with
  `DenyRoleChaining` and `DenyBoundaryRemoval`.
- IAM grants live in a second managed policy (`<user_name>-iam`, output
  `iam_policy_arn`) because the combined document exceeds the 6144-character
  managed-policy quota.

Upgrading an existing deployment: roles created by an earlier, unbounded
version of this user carry no boundary, so this user can no longer edit them.
Have an administrator attach the boundary (`aws iam put-role-permissions-boundary`)
or recreate the stack. The optional `deployment_safety` controller role from `bootstrap/aws-update-rollback-controller` carries its own boundary; wire it with an identity that owns that role.

`terraform test` in this directory checks the scope offline (real provider,
fake credentials, no AWS calls).

## Notes
- The policy is scoped to the AWS services used by the ECS/Fargate module (VPC, ECS, ALB, RDS,
  ElastiCache, CloudWatch Logs, Secrets Manager, KMS, S3, ACM, Route53, WAF).
- If you disable optional features (WAF, Route53, ACM, ALB access logs), you can remove those
  permissions from `main.tf`.
- If you set `create_access_key`, treat the key as a secret and rotate it out; the certified lane will not accept it.
