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

## Notes
- The policy is scoped to the AWS services used by the ECS/Fargate module (VPC, ECS, ALB, RDS,
  ElastiCache, CloudWatch Logs, Secrets Manager, KMS, S3, ACM, Route53, WAF).
- If you disable optional features (WAF, Route53, ACM, ALB access logs), you can remove those
  permissions from `main.tf`.
- If you set `create_access_key`, treat the key as a secret and rotate it out; the certified lane will not accept it.
