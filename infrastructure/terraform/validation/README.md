# Terraform Validation Assets

This folder contains maintainer-only Terraform validation automation.

- `scripts/aws`: AWS ECS + Lambda + data-stack integration validation
  Provider entrypoints are thin wrappers over `scripts/aws/lib/*`.
- `scripts/azure`: Azure ACA + Functions + data-stack integration validation
  Azure validation is already decomposed across `scripts/azure/lib/*`.
- `scripts/k8s`: local Kubernetes, AKS, and EKS integration validation helpers
  The generic Kubernetes entrypoint is a thin wrapper over `scripts/k8s/lib/*`.
- `scripts/shared`: policy gate and drift-detection scripts

For full run instructions, use:

- `docs/devops/terraform-validation.md`
- `.github/workflows/terraform-manual-validation.yml`
