# AWS ECS/Fargate Terraform Bootstrap Identity

Creates a least-privilege IAM policy surface for running the `modules/aws-ecs` Terraform module.
OIDC/workload identity federation is the preferred path; `create_iam_user` and
`create_access_key` remain as fallback switches.

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
- Use the `bootstrap_identity_contract` output as the integration contract for CI.
- Treat access keys as fallback secrets, not the default operating model.
