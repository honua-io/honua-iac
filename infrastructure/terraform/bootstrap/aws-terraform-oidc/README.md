# AWS Terraform OIDC backend access

This root creates the short-lived STS web-identity role used to access the separately bootstrapped S3 state bucket and DynamoDB lock table. It does not create static IAM users or access keys and it is not a deployment role.

The trust policy matches one exact issuer, audience, and subject. The inline policy is limited to state objects, bucket discovery, and lock-table operations. Deployment, workload, and application identities remain separate contracts.

Apply this root only after `bootstrap/aws-tfstate` has been applied. Supply the existing OIDC provider and the exact backend resource ARNs through variables. The `workload_identity_contract` output contains references and identity metadata only; tokens, credentials, state contents, and secrets are never outputs.

Terraform validation is the supported local check. No live AWS qualification is implied by a successful plan or validation.
