# AWS Terraform state backend bootstrap

This standalone root creates the remote state substrate required by the AWS
ECS release lane. Apply it separately before initializing the product stack.
It creates:

- an S3 bucket with versioning, server-side encryption, ownership enforcement,
  public-access blocking, HTTPS-only access, and `force_destroy = false`;
- a pay-per-request DynamoDB table with point-in-time recovery for Terraform
  state locking.

The root emits `backend_contract` and `backend_contract_digest`. They contain
resource identity, key scope, locking, encryption, and protection facts only;
they never contain credentials or Terraform state contents. The product
contract remains `unqualified` until an executor supplies the backend digest
and authoritative post-plan/post-apply state lineage from the exact remote
backend.

## Use

```powershell
terraform init
terraform plan -var='bucket_name=replace-with-a-globally-unique-name'
terraform apply -var='bucket_name=replace-with-a-globally-unique-name'
terraform output -json backend_contract
```

Copy `examples/aws/backend.tf.example` to the AWS example root only after this
bootstrap has succeeded, replacing the bucket/table placeholders with the
outputs from this root. The bootstrap state itself must use a separately
managed backend or an explicitly disposable local state during first apply.

This root does not create IAM users, access keys, OIDC providers, or workload
roles. Short-lived execution identity remains a separate #149 slice.
