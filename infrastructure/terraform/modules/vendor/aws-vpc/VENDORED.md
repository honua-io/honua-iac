Vendored from `terraform-aws-modules/vpc/aws` version `5.21.0`.

Local patch:
- `vpc-flow-logs.tf`: use `data.aws_region.current.id` instead of the deprecated `name` attribute so Terraform validation and tests are warning-free across the AWS provider versions currently used in this repo.
