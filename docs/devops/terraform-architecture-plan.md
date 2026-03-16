# Terraform Architecture Refactor Plan

This plan turns [ADR 0001](../adr/0001-terraform-architecture-refactor.md) into a migration sequence that preserves customer usability while reducing maintainer complexity.

## Goals

- keep customer deployment entrypoints simple and stable
- make integration validation contract-driven instead of output-scraping
- reduce the amount of logic embedded in large shell scripts and GitHub workflow YAML
- preserve real provider-native differences instead of hiding them behind a fake multi-cloud abstraction

## Non-goals

- rewriting every stack root in one change
- renaming all directories before the contracts and runner exist
- forcing provider-neutral modules where the cloud resources are materially different

## Current To Target Mapping

| Current path | Target role | Notes |
| --- | --- | --- |
| `modules/aws-ecs` | `platforms/aws-ecs` | Keep provider-native ECS deployment logic together. |
| `modules/aws-serverless` | `platforms/aws-serverless` | Remains Lambda-specific. |
| `modules/azure-aca` | `platforms/azure-aca` | Remains ACA-specific. |
| `modules/azure-functions` | `platforms/azure-functions` | Remains Functions-specific. |
| `modules/aws-eks` | `platforms/aws-eks` | Platform module for managed Kubernetes on AWS. |
| `modules/azure-aks` | `platforms/azure-aks` | Platform module for managed Kubernetes on Azure. |
| `modules/aws-data` | `components/data/aws-postgres-redis` | Concern-oriented component, still AWS-specific. |
| `modules/azure-data` | `components/data/azure-postgres-redis` | Concern-oriented component, still Azure-specific. |
| `modules/observability-stack` | `components/observability` | Shared add-on surface. |
| `examples/*` | `stacks/customer/*` | Preserve current roots as compatibility wrappers until migration is complete. |
| validation-only roots embedded in scripts | `stacks/test/*` | Explicit ephemeral and reusable validation compositions. |
| `validation/scripts/*` | `validation/adapters/*` plus `validation/runner/*` | Shell becomes adapter/shim, not the primary orchestration layer. |

## Phase 0: Baseline And Guardrails

Scope:

- document the target architecture
- keep current validation green while changes land
- decide the contract schema and migration policy

Paths:

- `docs/adr/0001-terraform-architecture-refactor.md`
- `docs/devops/terraform-architecture-plan.md`
- `infrastructure/terraform/README.md`
- `docs/devops/terraform-validation.md`

Acceptance criteria:

- maintainers have a single documented target architecture
- the migration plan names concrete directories and phases
- no existing customer deployment path changes yet

## Phase 1: Stack Contracts

Scope:

- add `deployment_contract`, `validation_contract`, and `operations_contract` outputs to deployable stacks
- keep legacy scalar outputs during the transition
- teach shared validation code to prefer the new contracts first

Priority order:

1. `examples/azure-functions`
2. `examples/aws-serverless`
3. `examples/azure`
4. `examples/aws`
5. `examples/azure-aks`
6. `examples/aws-eks`

Paths:

- `infrastructure/terraform/examples/*/main.tf`
- `infrastructure/terraform/modules/*/outputs.tf`
- `infrastructure/terraform/validation/scripts/shared/platform-post-apply-validation.sh`

Deliverables:

- every priority stack emits the three top-level contracts
- no contract contains raw secrets or raw connection strings
- post-apply validation can derive test configuration from contract outputs
- CI logs whether the contract path or legacy fallback path was used

Acceptance criteria:

- `platform-post-apply-validation.sh` can run from `terraform output -json` without assuming provider-specific scalar output names
- recent cloud validation paths still pass while legacy outputs remain

Recommended first slice:

- implement the three contracts in `examples/azure-functions/main.tf`
- implement the three contracts in `examples/aws-serverless/main.tf`
- add a shared contract loader in `platform-post-apply-validation.sh`
- keep the existing `control_plane_*` outputs temporarily as compatibility shims

## Phase 2: Normalize Shell Adapters

Scope:

- bring AWS and Kubernetes validation orchestration to the same decomposition standard as Azure
- extract shared concerns such as logging, Terraform lifecycle, quota checks, and reusable data-stack handling

Paths:

- `infrastructure/terraform/validation/scripts/aws/run-aws-terraform-integration.sh`
- `infrastructure/terraform/validation/scripts/k8s/run-k8s-terraform-integration.sh`
- `infrastructure/terraform/validation/scripts/shared/*`
- new provider-specific library folders under `validation/scripts/aws/lib` and `validation/scripts/k8s/lib`

Deliverables:

- provider entrypoints become small orchestration shells
- common lifecycle and validation helpers move to shared library functions
- provider-specific logic is grouped by responsibility instead of one giant script

Acceptance criteria:

- no provider entrypoint remains a multi-thousand-line orchestration script
- the same validation scenario can be traced through a small number of explicit functions

## Phase 3: Scenario Manifests And Typed Runner

Scope:

- replace most shell orchestration with a typed runner
- move stack selection, platform capabilities, and lifecycle policy into declarative scenario manifests

Paths:

- `infrastructure/terraform/validation/scenarios/*.yaml`
- `infrastructure/terraform/validation/runner/*`
- `.github/workflows/terraform-manual-validation.yml`

Representative scenario shape:

```yaml
id: azure-functions-ephemeral
stack_root: infrastructure/terraform/stacks/test/azure-functions-ephemeral
platform: azure-functions
profile: ephemeral
contracts:
  deployment: deployment_contract
  validation: validation_contract
  operations: operations_contract
steps:
  - terraform_init
  - terraform_apply
  - readiness_check
  - protocol_smoke
  - admin_crud
  - cloud_post_apply
  - terraform_destroy
```

Deliverables:

- workflow inputs map to scenario ids instead of many per-platform booleans
- the runner owns apply, destroy, retries, artifact capture, and contract loading
- shell remains only as a thin adapter layer while the migration completes

Acceptance criteria:

- GitHub workflow YAML becomes a dispatcher, not the main orchestration engine
- scenario behavior is reviewable in versioned manifests without reading a giant script

## Phase 4: Recompose Customer And Test Stacks

Scope:

- extract real shared Terraform components where duplication is meaningful
- create explicit customer-facing stacks and explicit maintainer test stacks

Paths:

- `infrastructure/terraform/components/*`
- `infrastructure/terraform/platforms/*`
- `infrastructure/terraform/stacks/customer/*`
- `infrastructure/terraform/stacks/test/*`

Deliverables:

- customer stacks focus on deployment intent
- test stacks focus on validation lifecycle and data reuse
- current `examples/*` roots become wrappers or aliases during the transition

Acceptance criteria:

- customer stacks can be documented without exposing validation-only knobs
- validation stacks can evolve without destabilizing the operator-facing interface

## Phase 5: Remove Compatibility Shims

Scope:

- delete legacy scalar outputs once the runner and tests fully use contract outputs
- retire obsolete shell paths and workflow branches
- move or remove old directories after the new structure is stable

Acceptance criteria:

- validation no longer depends on `control_plane_*` scalar outputs
- old example wrappers can either be removed or reduced to thin compatibility roots
- there is one canonical path for each customer deployment mode and each validation scenario

## Risks And Controls

Risk: contract sprawl becomes another ungoverned surface.
Control: keep exactly three top-level contracts and version them explicitly.

Risk: migration breaks existing validation while contracts are incomplete.
Control: use contract-first with legacy fallback and log the active path in CI.

Risk: platform-neutral components become a false abstraction.
Control: allow concern-oriented components to remain provider-specific when necessary.

Risk: customer stacks get polluted with maintainer-only variables.
Control: move validation-only composition into `stacks/test/*`, not `stacks/customer/*`.

## Recommended Next Implementation Step

Implement Phase 1 for the serverless paths first.

That means:

1. add the three contracts to `examples/azure-functions/main.tf`
2. add the three contracts to `examples/aws-serverless/main.tf`
3. update `platform-post-apply-validation.sh` to prefer contracts and fall back to legacy outputs
4. validate those two paths in the manual workflow before expanding to ACA, ECS, AKS, and EKS
