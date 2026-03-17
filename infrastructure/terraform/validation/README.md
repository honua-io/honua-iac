# Terraform Validation Assets

This folder contains maintainer-only Terraform validation automation.

- `runner/Honua.TerraformValidation.Runner`: `.NET 10` typed workflow runner that validates inputs, bootstraps least-privilege identities, and dispatches validation scenarios
- `scenarios/`: declarative scenario manifests consumed by the runner
- `adapters/aws`: AWS runner-facing adapter entrypoints
- `adapters/azure`: Azure runner-facing adapter entrypoints
- `adapters/k8s`: Kubernetes runner-facing adapter entrypoints
- `adapters/shared`: compatibility entrypoints that translate policy-gate and drift calls back into the `.NET 10` runner
- `scripts/*`: legacy shell fallback harnesses retained for compatibility and reference

Current live-scenario split:

- `azure-live`, `aws-live`, `k8s-live`, `aks-live`, and `eks-live` are runner-native scenarios executed by the `.NET 10` runner.
- The shell adapter entrypoints remain stable compatibility shims. They invoke the runner when `dotnet` is available and fall back to the legacy shell harnesses only when the runner is unavailable.
- Azure, AWS, AKS, and EKS can also invoke the external `honua-server` post-apply platform suite when that repo is checked out and `HONUA_PLATFORM_VALIDATION_SCRIPT` is set or auto-discovered.

For full run instructions, use:

- `docs/devops/terraform-validation.md`
- `.github/workflows/terraform-manual-validation.yml`
