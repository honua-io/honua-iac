# AWS Serverless Terraform Bootstrap Identity

Creates a service-scoped IAM bootstrap surface for Lambda/API Gateway style deployments.
OIDC/workload identity federation is the preferred path; `create_iam_user` and
`create_access_key` remain as fallback switches.

## Usage
```bash
terraform init
terraform apply
```

## Notes
- This is a baseline for Lambda + API Gateway + container image deployments.
- Includes Postgres (RDS) and Redis permissions for serverless Honua stacks.
- Some IAM/service-linked-role actions remain wildcard-scoped because the underlying AWS APIs do
  not support useful resource-level restriction for bootstrap workflows.
- Service-linked-role creation is restricted to the Lambda and API Gateway service principals
  expected by this stack.
- If you are not using ECR or S3, remove those permissions.
- Use the `bootstrap_identity_contract` output as the integration contract for CI.
- Treat access keys as fallback secrets, not the default operating model.
