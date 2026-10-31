# AWS update/rollback controller identity

The independent retained controller role for honua-release `aws-update-rollback.yml`
(`docs/AWS-UPDATE-ROLLBACK-PRODUCER.md`). The producer job runs as `honua-release-cicd` and
assumes this role with session name `honua-update-rollback-controller`. The retained
controller and the read-only candidate schema probe then run with those credentials.

What it grants:

- **Floor policy** (`<name>-floor`): Lambda alias read/update on cell functions
  (`honuar*`, `honuan*`) for the `honua-gitops-aws-lambda` backend, and CloudWatch metric
  reads for the `aws-cloudwatch` telemetry connection. Requests outside us-east-1 are denied.
- **Per-cell ECS grant**: `examples/aws` with `deployment_safety` attaches `<cell>-recovery`
  (ecs:UpdateService on the canary service, ModifyRule on the protected listener rule) and
  removes it on destroy. This root does not own that grant.
- **Permissions boundary** (`<name>-boundary`): caps every inline policy at ECS/ALB rollout,
  Lambda alias switching, CloudWatch reads, and restore of `restore_name_prefixes`. It denies
  `Environment=cert|demo` resources except those prefix ARNs, and denies RDS and secret
  deletion. An empty `restore_name_prefixes` keeps the blanket cert/demo deny and grants no
  restore. It exists because `honua-release-cicd` may put inline policies on this role.

The role and boundary live outside the `honuar*`/`honuan*`/`honuaeks*` cell namespaces, so no
cell or the reaper can own them.

## Apply

State is in the account's state bucket, at the same key as before. The backend
moved from a tracked partial `backend "s3" {}` block to `backend.tf.example`
(AGENTS.md; honua-iac#320). An existing working directory needs
`terraform init -reconfigure` once; the state itself does not move.

The release session applies this. Do not apply it from a product lane.

```sh
cd infrastructure/terraform/bootstrap/aws-update-rollback-controller
sed 's/REPLACE_WITH_STATE_BUCKET_NAME/honua-tfstate-585192672263/' backend.tf.example > backend.tf
terraform init -reconfigure
terraform plan -var='restore_name_prefixes=["honua-cert-"]' -out=controller.tfplan
terraform apply controller.tfplan
```

Applied 2026-10-21 in 585192672263. Output `controller_role_arn` is honua-release variable
`HONUA_UPDATE_ROLLBACK_CONTROLLER_ROLE_ARN`, and `controller_role_name` is
`HONUA_UPDATE_ROLLBACK_ECS_SAFETY.controller_role_name`.

## Required change to `honua-release-cicd` (not managed by Terraform)

`release-cicd-guardrails` is an operator-managed inline policy on `honua-release-cicd`. Before
this change it denied all `sts:AssumeRole` and all IAM writes outside the cell namespaces, so
the producer could neither assume this role nor let an ECS cell attach its recovery grant. The
exceptions applied on 2026-10-21 are recorded in `cicd-guardrail-exceptions.json`:

- `sts:AssumeRole` is denied everywhere except this role.
- This role's ARN is added to `DenyIamOutsideCellNamespace`'s NotResource.
- On this role, every IAM action except inline-policy put/delete and reads is still denied:
  no DeleteRole, trust-policy update, managed-policy attach or boundary change.

`aws iam simulate-principal-policy` for `honua-release-cicd` against this role returns:
AssumeRole, PutRolePolicy and DeleteRolePolicy `allowed`; DeleteRole,
PutRolePermissionsBoundary, and CreatePolicyVersion on the boundary `explicitDeny`.
