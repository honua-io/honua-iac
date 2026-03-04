# Terraform Validation Assets

This folder contains maintainer-only Terraform validation automation.

- `scripts/aws`: AWS ECS + Lambda + data-stack integration validation
- `scripts/azure`: Azure ACA + Functions + data-stack integration validation
- `scripts/k8s`: local Kubernetes, AKS, and EKS integration validation helpers
- `scripts/shared`: policy gate and drift-detection scripts

For full run instructions, use:

- `docs/devops/terraform-validation.md`
- `.github/workflows/terraform-manual-validation.yml`
