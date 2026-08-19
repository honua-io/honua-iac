# AWS EKS Module

Provisions a minimal Amazon EKS cluster and VPC for integration validation flows.

> Internal-only; not part of the published module surface. See
> [`docs/module-versioning.md`](../../../../docs/module-versioning.md).

## What it provisions

- VPC with public/private subnets and NAT gateway
- EKS control plane
- EKS managed node group

## Secret encryption

By default the module mints a KMS CMK and uses it to envelope-encrypt Kubernetes
secrets — the production shape. That is the wrong default for a cluster that
lives for an hour: `terraform destroy` can only *schedule* a CMK for deletion,
7 days is the shortest window AWS accepts, and the key bills the whole time
(honua-release#127). Two knobs:

- `cluster_secret_encryption_enabled = false` — no CMK is created and no
  `encryption_config` is set. Use this for ephemeral parity/validation cells,
  which certify nothing about envelope encryption.
- `cluster_secret_encryption_key_arn = "arn:aws:kms:..."` — encrypt with a
  long-lived key created once and never destroyed. Use this instead when the
  cells *are* meant to keep the encryption path under test.

## Example

```hcl
module "eks" {
  source = "../../modules/aws-eks"

  name_prefix = "honua"
  environment = "it"
}
```

## Outputs

- `environment`
- `cluster_name`
- `cluster_arn`
- `cluster_endpoint`
- `cluster_certificate_authority_data`
- `vpc_id`
- `control_plane_target_kind = "Kubernetes"`
- `control_plane_backend_name = "honua-gitops-kubernetes"`
- `control_plane_telemetry_policy = "kubernetes-honua-http"`
- `honua_metrics_target = "honua"` for the standard Helm release naming convention
