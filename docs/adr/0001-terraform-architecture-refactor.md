# ADR 0001: Layer Terraform around stack contracts, platform modules, and scenario-driven validation

- Status: Accepted
- Date: 2026-03-16

## Context

The current Terraform repository already has a useful split between:

- provider-native runtime modules under `infrastructure/terraform/modules/*`
- thin deployable entrypoints under `infrastructure/terraform/examples/*`
- maintainer-only validation automation under `infrastructure/terraform/validation/*`

That split is directionally correct, but the maintainer surface has become too implicit and too script-heavy:

- deployable stacks re-export many provider-specific outputs such as `control_plane_*`, cluster names, app names, resource groups, and connection details
- validation scripts infer behavior from that output soup instead of consuming a stable contract
- `.github/workflows/terraform-manual-validation.yml` carries a large amount of policy, defaults, and environment-specific wiring
- AWS and Kubernetes validation still rely on monolithic shell orchestration, while Azure has only partially moved toward a library-based shape
- cross-repo post-apply validation depends on environment variables rendered from ad hoc Terraform outputs rather than a defined stack interface

The result is high change cost. Small behavior changes require touching workflow YAML, long shell scripts, Terraform outputs, and post-apply test plumbing at the same time.

## Decision

### 1. Keep provider-native platform modules

We will not build a single multi-cloud mega-module with a `platform = "aws|azure|k8s"` switch.

Provider-specific behavior will continue to live in provider-native modules, because the runtime and operations models are materially different across:

- ECS and Lambda
- Azure Container Apps and Azure Functions
- AKS and EKS

Customer-facing stacks remain thin, opinionated compositions over those provider-native modules.

### 2. Introduce stable stack contracts

Every deployable stack will emit three structured outputs:

- `deployment_contract`
- `validation_contract`
- `operations_contract`

These outputs replace the current pattern of re-exporting long lists of loosely related provider-specific outputs.

The contracts are the stable handoff between:

- Terraform stacks
- validation orchestration
- post-apply cloud tests
- operator documentation and day-2 automation

Legacy scalar outputs may remain during migration, but new automation must prefer the contract outputs first.

### 3. Define contract contents by responsibility

`deployment_contract` is the stable description of what was deployed and how traffic reaches it.

It contains:

- schema version
- stack id, platform, runtime class, region, environment
- public and internal endpoints
- workload identity and resource ids
- rollout metadata such as backend name, target id, current revision, desired revision
- dependency references for data, cache, ingress, and secret stores

`validation_contract` is the maintainer-facing description of how integration tests should exercise the deployment.

It contains:

- platform capabilities such as deploy-plan, mutation, scale, backup, idempotency, and protocol support
- readiness and smoke-test endpoints
- test data setup expectations
- reusable infrastructure hints
- cleanup and destroy expectations
- references to platform-specific artifacts required by validation

`operations_contract` is the operator-facing description of day-2 resources and attachments.

It contains:

- observability endpoints and selectors
- secret store references
- backup and resilience configuration
- scaling envelopes
- resource grouping metadata
- cost and TTL metadata when the stack is ephemeral

Raw secrets and connection strings must not be emitted in these contracts. Contracts can reference secret ids, secret names, or managed-secret resources instead.

### 4. Use an explicit contract shape

The first contract version is `v1`.

Representative shape:

```hcl
output "deployment_contract" {
  value = {
    schema_version = "v1"
    stack = {
      id          = "azure-functions"
      platform    = "azure-functions"
      runtime     = "serverless"
      environment = var.environment
      region      = var.location
    }
    endpoints = {
      public_base_url = module.honua.function_app_url
      readiness_path  = "/healthz/ready"
      admin_base_path = "/api/v1/admin"
      protocol_path   = "/v1"
    }
    workload = {
      kind        = "AzureFunctions"
      name        = module.honua.function_app_name
      resource_id = module.honua.function_app_id
    }
    rollout = {
      backend_name     = module.honua.control_plane_backend_name
      target_id        = module.honua.control_plane_target_id
      target_name      = module.honua.control_plane_target_name
      target_resource  = module.honua.control_plane_target_resource_id
      current_revision = module.honua.control_plane_current_revision
      desired_revision = module.honua.control_plane_desired_revision
    }
    dependencies = {
      database = {
        kind      = "azure-postgres"
        fqdn      = module.honua.db_fqdn
        secret_ref = null
      }
      cache = {
        kind       = "azure-redis"
        enabled    = var.redis_enabled
        secret_ref = null
      }
    }
  }
}
```

Representative `validation_contract` shape:

```hcl
output "validation_contract" {
  value = {
    schema_version = "v1"
    platform = {
      name = "azure-functions"
      capabilities = {
        deploy_plan  = var.deployment_slot_enabled
        mutation     = false
        scale_check  = true
        backup_drill = true
        idempotency  = true
      }
    }
    tests = {
      readiness_url = "${module.honua.function_app_url}/healthz/ready"
      admin_url     = "${module.honua.function_app_url}/api/v1/admin"
      protocol_url  = "${module.honua.function_app_url}/v1"
    }
    artifacts = {
      terraform_root = path.cwd
      resource_group = module.honua.resource_group_name
    }
    lifecycle = {
      reuse_data_stack = true
      destroy_mode     = "ephemeral"
    }
  }
}
```

Representative `operations_contract` shape:

```hcl
output "operations_contract" {
  value = {
    schema_version = "v1"
    observability = {
      telemetry_policy = module.honua.control_plane_telemetry_policy
      grafana_url      = null
      prometheus_job   = null
    }
    secrets = {
      admin_password_secret = null
      db_connection_secret  = null
      redis_connection_secret = null
    }
    grouping = {
      resource_group = module.honua.resource_group_name
      tags           = var.tags
    }
  }
}
```

Field names can differ slightly by platform, but the top-level contract keys and semantics must remain stable.

### 5. Restructure the repository by responsibility

Target repository shape:

```text
infrastructure/terraform/
  components/
    data/aws-postgres-redis/
    data/azure-postgres-redis/
    identity/
    ingress/
    observability/
    rollout/
  platforms/
    aws-ecs/
    aws-serverless/
    azure-aca/
    azure-functions/
    aws-eks/
    azure-aks/
  stacks/
    customer/
    test/
  validation/
    scenarios/
    runner/
    adapters/
```

Rules:

- `components/` hold reusable concern-oriented Terraform pieces. They may still be provider-specific when the underlying resources differ.
- `platforms/` hold provider-native Honua deployment compositions.
- `stacks/customer/` hold the operator-facing entrypoints that customers actually apply.
- `stacks/test/` hold ephemeral and reusable validation stacks used only by maintainers and CI.
- `validation/scenarios/` hold declarative scenario manifests.
- `validation/runner/` holds a typed runner that executes scenarios.
- `validation/adapters/` holds thin provider-specific adapters and any temporary legacy shell shims.

### 6. Move orchestration out of workflow YAML and large shell scripts

GitHub Actions should become a thin dispatcher that selects:

- the scenario manifest
- the environment or approval profile
- the credential source

The workflow should not remain the primary home for:

- runtime defaults
- platform capability policy
- stack-specific branching
- data-stack reuse logic
- provider cleanup policy
- cross-repo post-apply test handoff

Those responsibilities move into a typed validation runner and declarative scenario files.

The typed runner may be implemented in Go or .NET, but the architecture assumes:

- scenario parsing is typed
- Terraform apply and destroy state is explicit
- contract loading uses `terraform output -json`
- provider-specific behavior is isolated behind adapters
- post-apply test invocation consumes contract data, not hand-built environment-variable heuristics

### 7. Migrate compatibly

Migration is contract-first, not rename-first.

That means:

- keep current customer stack roots working during migration
- add contract outputs before removing legacy outputs
- update validation to prefer contract outputs with fallback to legacy scalars
- split scripts before replacing them
- move directories only after the runner and contracts are stable

## Consequences

### Positive

- customer deployment entrypoints stay simple and stable
- provider-specific complexity stays where it belongs
- validation logic can stop scraping provider-specific Terraform outputs
- GitHub workflow YAML becomes smaller and easier to reason about
- future platforms can implement the contract without copying another monolithic script

### Negative

- there is short-term duplication while legacy outputs and contract outputs coexist
- migration requires touching every deployable stack and validation path
- the typed runner introduces a new code surface that must be maintained

## Rejected Alternatives

### One universal multi-cloud module

Rejected because it hides provider differences behind conditionals and turns the module into the next monolith.

### Keep shell orchestration and only split files further

Rejected because file splitting alone does not solve the missing contract boundary or the amount of implicit policy hidden in environment variables.

## Phase 1 Starting Point

Phase 1 starts by adding contract outputs to the highest-value deployable stacks first:

- `examples/azure-functions`
- `examples/aws-serverless`
- `examples/azure`
- `examples/aws`

The shared post-apply validation path then switches to:

1. read `deployment_contract`, `validation_contract`, and `operations_contract` when present
2. fall back to current scalar outputs during the transition
3. log which path was used so migration gaps are visible in CI
