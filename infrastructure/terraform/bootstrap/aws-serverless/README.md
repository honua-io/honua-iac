# AWS Serverless Terraform Bootstrap Identity

Creates a least-privilege IAM policy surface for Lambda/API Gateway style deployments. OIDC/workload
identity federation is the preferred path; `create_iam_user` and `create_access_key` remain as
fallback switches.

## Usage
```bash
terraform init
terraform apply
```

## Notes
- This is a baseline for Lambda + API Gateway + container image deployments.
- Includes Postgres (RDS) and Redis permissions for serverless Honua stacks.
- If you are not using ECR or S3, remove those permissions.
- Use the `bootstrap_identity_contract` output as the integration contract for CI.
- Treat access keys as fallback secrets, not the default operating model.
