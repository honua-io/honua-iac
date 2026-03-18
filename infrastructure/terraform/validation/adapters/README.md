# Validation Adapters

Adapters are the compatibility boundary between historical shell entrypoints and the `.NET 10` validation runner.

## Runner vs Wrapper Boundary

- Use the runner directly from GitHub Actions and for new local automation.
- Keep adapter entrypoints stable for humans, CI glue, and older scripts that still call shell commands.
- Do not point new orchestration at `validation/scripts/*` directly. That layer is private implementation detail.

## Current Behavior

| Adapter family | Current behavior |
|---|---|
| `adapters/shared` | Runner-first shims for `policy-gates` and `drift` |
| `adapters/azure` | Runner-first compatibility shims for `azure-live` and `aks-live`, with legacy fallback only when the runner is unavailable |
| `adapters/aws` | Runner-first compatibility shims for `aws-live` and `eks-live`, with legacy fallback only when the runner is unavailable |
| `adapters/k8s` | Runner-first compatibility shim for `k8s-live`, with legacy fallback only when the runner is unavailable |

## Practical Rule

If you are documenting or wiring a new path:

1. Prefer `dotnet run --project ...Honua.TerraformValidation.Runner -- <scenario>`.
2. Use adapters only when you need stable shell-compatible entrypoints.
3. Treat `validation/scripts/*` as legacy implementation detail or shared asset source, never as the primary orchestration surface.
