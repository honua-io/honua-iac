# Validation Adapters

These adapter entrypoints are the runner-facing compatibility boundary for
Terraform validation.

- `adapters/azure/run-aks-terraform-integration.sh` and
  `adapters/aws/run-eks-terraform-integration.sh` are runner-first compatibility
  shims. They invoke the `.NET 10` runner when `dotnet` is available and fall
  back to the legacy shell implementations under `validation/scripts/` only when
  the runner is unavailable.
- `adapters/k8s`, `adapters/azure/run-azure-terraform-integration.sh`, and
  `adapters/aws/run-aws-terraform-integration.sh` now use that same runner-first
  compatibility pattern.
- `adapters/shared` now forwards `policy-gates` and `drift` back into the `.NET
  10` runner so those shared scenarios are runner-native while keeping the shell
  entrypoints stable.
