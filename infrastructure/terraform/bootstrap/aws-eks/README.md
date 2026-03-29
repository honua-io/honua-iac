# AWS EKS Terraform Service Account

Creates a service-scoped IAM bootstrap surface for running the
`modules/aws-eks` Terraform module.

## Usage
```bash
terraform init
terraform apply
```

## Notes
- The policy is scoped to AWS services used by the EKS/VPC modules
  (EKS, VPC/EC2, IAM, autoscaling, CloudWatch Logs, KMS).
- OIDC provider and some IAM read/create actions remain wildcard-scoped because the underlying AWS
  APIs do not provide useful resource-level restriction for bootstrap workflows.
- Service-linked-role creation is restricted to the EKS, nodegroup, Fargate, autoscaling, and ALB
  service principals expected by this stack.
- Treat the access key as a secret and prefer workload identity federation.
