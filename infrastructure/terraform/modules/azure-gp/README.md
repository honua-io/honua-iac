# modules/azure-gp — Azure GP-on-Batch substrate (single-pool MVP)

The Azure equivalent of the AWS GP-over-Batch substrate
(`modules/aws-serverless` with `enable_gp_batch`, honua-iac#70). It provisions
the **durable** Azure Batch substrate the Honua server's `ExecutionJobReconciler`
submits geoprocessing / import jobs onto via the `AzureBatchComputeBackend`
(`Backend = honua-azure-batch`).

## Why single-pool (and not the 4-tier pool)

AWS Batch sizes **per-task** (vCPU/memory are SubmitJob overrides), so the AWS
substrate mints a *pool of job definitions* that differ only by ephemeral
storage. Azure Batch sizes **per-pool** (VM size is a pool property), so the
natural analog would be one pool per size tier. The MVP instead runs **one
pool** because Azure scale-to-zero economics favor it: an autoscaling pool that
drains to **0 nodes** between jobs costs nothing idle, so a single right-sized
pool is the cheapest correct starting point. Per-tier pools (s/m/l/xl VM sizes)
are a **fast-follow**, not part of this MVP.

## Resources

| Resource | Role | AWS analog |
| --- | --- | --- |
| `azurerm_batch_account.gp` | Batch control surface; its `account_endpoint` is the data-plane URL | (Batch account / region) |
| `azurerm_batch_pool.gp` | ONE container-capable pool, autoscale 0→N→0 | Fargate-Spot compute env (scale-to-zero) |
| `azurerm_user_assigned_identity.gp_task` | Pool/task run-as identity (ACR pull, blob write, KV read) | Batch job (task) IAM role |
| `azurerm_container_registry.worker_gdal` | Hosts the worker-gdal image (gated by `create_worker_gdal_acr`) | worker-gdal ECR repo (`create_worker_gdal_repo`) |
| `azurerm_storage_account` + `azurerm_storage_container.gp_output` | Blob output staging | S3 data/artifact bucket |
| `azurerm_role_assignment.*` | `AcrPull`, `Storage Blob Data Contributor`, optional `Key Vault Secrets User` | scoped IAM job-role policies |

Everything is gated behind `enable_azure_gp_substrate` (default `false`),
mirroring `enable_gp_batch` so existing deploys are unchanged unless an operator
opts in.

## The single-pool autoscale formula (scale-to-zero)

The pool uses an Azure Batch [autoscale formula](https://learn.microsoft.com/azure/batch/batch-automatic-scaling)
(`auto_scale`, no fixed `target_*_nodes`) — the Azure analog of the AWS Fargate
compute environment scaling to `min_vcpus = 0`:

```text
// Honua GP scale-to-zero autoscale formula (single-pool MVP).
$samples = $PendingTasks.GetSamplePercent(TimeInterval_Minute * 5);
$pending = ($samples < 50 ? max(0, $PendingTasks.GetSample(1)) : max($PendingTasks.GetSample(TimeInterval_Minute * 5)));
$target  = min($pending, <gp_pool_max_nodes>);
$TargetLowPriorityNodes = $target;   // or $TargetDedicatedNodes when gp_pool_use_low_priority = false
$TargetDedicatedNodes   = 0;         // the other knob is pinned to 0
$NodeDeallocationOption  = taskcompletion;
```

- Samples pending (active+running) tasks over the last 5 minutes; uses the
  **max** over the window so a brief sampling gap does not scale a still-busy
  pool to zero. Falls back to a 1-minute sample when the window has too few
  samples to be reliable.
- Targets **one node per pending task**, capped at `gp_pool_max_nodes`.
- With **no pending work the target is 0**, so the pool **drains to zero nodes**
  (scale-to-zero) — you pay only while a job's container actually runs.
- `$NodeDeallocationOption = taskcompletion` lets an in-flight task finish before
  its node is reclaimed on scale-down (no mid-task kill from autoscale).

### Low-priority (Spot) vs dedicated — preemption risk

`gp_pool_use_low_priority` defaults **`true`**: the formula drives
low-priority (Spot) nodes, which are substantially cheaper. **Preemption risk:**
Azure can reclaim a low-priority node mid-job. GP jobs that cannot checkpoint /
resume — long-running or non-idempotent ones — should set
`gp_pool_use_low_priority = false` to run on dedicated nodes. The Batch task
retry (a SubmitTask runtime parameter the server sets, `max_task_retry_count`)
mitigates transient preemption for idempotent jobs.

## Output contract (v1) — exact names

Consumers (the honua-devops adapter + the server) read these as **opaque**
runtime config. The param-key strings the server reads were verified against
`honua-server` `AzureBatchComputeBackend.cs`:

| Output | Server param key | Notes |
| --- | --- | --- |
| `gp_batch_account_url` | `azure.batch.account_url` | `https://` + `account_endpoint` |
| `gp_pool_id` | `azure.batch.pool_id` | the single pool's name |
| `gp_output_container_url` | `azure.storage.output_container_url` | blob endpoint + container name |
| `gp_control_plane_backend_name` | (matches `BackendIdentifier`) | constant `honua-azure-batch` |
| `gp_batch_account_id` | — | Batch account resource id |
| `gp_task_identity_id` / `gp_task_identity_principal_id` / `gp_task_identity_client_id` | — | task identity (job-role analog) |
| `gp_acr_login_server` | — | for image push (null unless `create_worker_gdal_acr`) |

All outputs are `null` when `enable_azure_gp_substrate = false`.

## Deployment topology — the control-plane decision

GP execution on Azure Batch follows the **same topology** as AWS Batch:

```
  ┌─────────────────────────┐     ┌──────────────────────────┐
  │  Serverless API tier     │     │  ALWAYS-ON control plane │
  │  (Functions / API host)  │     │  (the Honua server's     │
  │  request/response only    │     │   reconcilers, scheduler,│
  └─────────────────────────┘     │   job-workers)           │
                                   │  on a long-running host: │
                                   │  ACA / AKS / on-prem      │
                                   └────────────┬─────────────┘
                                                │ submits + observes
                                                ▼
                                   ┌──────────────────────────┐
                                   │  Ephemeral Batch compute  │
                                   │  (this module: ONE pool,  │
                                   │   autoscale → 0 when idle) │
                                   └──────────────────────────┘
```

- The **in-process scheduler / reconcilers** (`ExecutionJobReconciler` and the
  job-workers) run **inside the Honua server** as background loops. They require
  an **always-on control-plane host** — a long-running container (Azure
  Container Apps with `min_replicas >= 1`, AKS, or on-prem). They are **not**
  compatible with a scale-to-zero serverless host (Azure Functions consumption /
  AWS Lambda) because a host that idles to zero would stop reconciling submitted
  jobs.
- The **Batch compute** (this module's pool) is **ephemeral** and scales to
  zero between jobs.
- This is **why there is no external trigger** (no Azure Scheduler / Event Grid
  timer, no AWS EventBridge rule) wiring jobs into Batch: the scheduler already
  lives in the always-on control plane and submits directly. The substrate here
  is durable infrastructure the control plane drives; it is not event-triggered
  on its own.

See `examples/azure-cert` for a Honua-owned stack that wires this module +
GitHub-OIDC federation so a dispatched cert workflow can `terraform apply` with
no client secret.

## Inputs (selected)

| Variable | Default | Notes |
| --- | --- | --- |
| `enable_azure_gp_substrate` | `false` | master feature gate |
| `gp_pool_vm_size` | `Standard_D4s_v3` | pool VM size (substrate-level compute) |
| `gp_pool_use_low_priority` | `true` | Spot nodes (see preemption note) |
| `gp_pool_max_nodes` | `4` | autoscale ceiling |
| `create_worker_gdal_acr` | `false` | mint the worker-gdal ACR |
| `gp_output_container_name` | `gp-output` | blob output container |
| `gp_task_key_vault_id` | `""` | optional KV read grant |

## Notes

- The storage account disables shared-key access; the task identity uses Azure
  AD (RBAC) tokens via its `Storage Blob Data Contributor` grant.
- The ACR has `admin_enabled = false`; the pool authenticates via its
  user-assigned identity (`AcrPull` + a `start_task` that runs `az acr login`).
- `#checkov:skip` justifications for Premium-only ACR features and the public
  blob/ACR endpoints (the scale-to-zero pool has no fixed egress IP / private
  endpoint in the MVP) are carried inline in `main.tf`.
