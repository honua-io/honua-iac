# AWS Data Module (internal)

> Internal-only; not part of the published module surface. See
> [`docs/module-versioning.md`](../../../../docs/module-versioning.md).

Building block that provisions the AWS data plane (VPC + RDS PostgreSQL) used by
`infrastructure/terraform/examples/aws-data`. It has no stabilised public
contract. External consumers should depend on a Tier 1 runtime module
(`aws-ecs` or `aws-serverless`) instead of pinning this module by Git source.
