# Evaluation: AKS Virtual Nodes / ACI support for validation

- Status: Recommendation delivered
- Date: 2026-06-24
- Tracking issue: [#12](https://github.com/honua-io/honua-iac/issues/12)
- Scope: written evaluation only; no module or workflow changes are made by
  this document.

## Summary recommendation

**Keep the AKS validation path VM-backed only. Do not add an AKS Virtual Nodes
/ ACI path to the `azure-aks` module.**

Virtual Nodes (the Azure Container Instances–backed virtual-kubelet) cannot host
the Honua validation scenario as it exists today, and the parts it *could* host
would certify a materially different and more constrained runtime than any
operator actually uses. The serverless-adjacent appeal is real but the
limitations are disqualifying for a validation workload. Recommendation: leave
a documented, optional follow-up (below) rather than implement now.

## What the validation path actually deploys

Grounded in the current code:

- `infrastructure/terraform/modules/azure-aks/main.tf` provisions a resource
  group and a single `azurerm_kubernetes_cluster` with one
  `default_node_pool` (name `system`, `Standard_D2s_v3` by default), cluster
  autoscaler (`auto_scaling_enabled = true`, min 1 / max 5), Azure CNI
  (`network_plugin = "azure"`), Azure network policy, system-assigned identity,
  Azure AD RBAC, and optional Log Analytics diagnostics. There is **no**
  `aci_connector_linux` / virtual-node profile in the module.
- `infrastructure/terraform/validation/scripts/azure/run-aks-terraform-integration.sh`
  applies that module and hands off to the shared Kubernetes path,
  `infrastructure/terraform/validation/scripts/k8s/run-k8s-terraform-integration.sh`.
- The shared k8s path installs the Honua Helm chart
  (`infrastructure/helm/honua`) with an **nginx** ingress class, applies the
  in-cluster `postgis/postgis:17-3.5` Deployment
  (`infrastructure/terraform/validation/scripts/k8s/k8s/postgis.yaml`,
  single replica, `emptyDir`), and installs Prometheus/Grafana via the
  `observability-stack` module.

So, as with EKS, the validation workload is a web Deployment + nginx ingress
controller + an in-cluster stateful database + a DaemonSet-bearing
observability stack — not a single stateless pod.

## How Virtual Nodes / ACI actually work

AKS Virtual Nodes is the `aci_connector_linux` add-on: a **virtual-kubelet**
that surfaces a synthetic node in the cluster. Pods scheduled to that node are
not run on a VM; each is launched as an Azure Container Instance group. To land
there a pod must explicitly target the virtual node (nodeSelector
`kubernetes.io/role: agent` + `type: virtual-kubelet`) and tolerate its taint
(`virtual-kubelet.io/provider`). It requires an **Azure CNI** cluster with a
delegated subnet for ACI. Crucially, AKS still requires at least one real
VM-backed system node pool — **Virtual Nodes can never be the whole cluster**.

## Why Virtual Nodes / ACI does not fit cleanly

### Compute model

- **Cannot replace the node pool.** A Virtual-Nodes-only validation cluster is
  not possible: AKS mandates a real system node pool for CoreDNS, metrics-
  server, tunnelfront/konnectivity, and the ACI connector pod itself. So this
  would only ever be an *additional* place to run the Honua web Deployment, not
  a way to remove VMs. The issue's "serverless-adjacent validation mode" can at
  best mean "run the stateless web pods on ACI while everything else stays on
  the VM pool."
- **Opt-in scheduling only.** Nothing runs on Virtual Nodes unless it carries
  the nodeSelector + toleration. The Honua chart and postgis manifest set
  neither, so they would require chart/manifest overrides to target ACI.

### Networking

- **Azure CNI + delegated subnet required.** The module defaults to
  `network_plugin = "azure"` (good), but Virtual Nodes also needs a dedicated
  subnet delegated to `Microsoft.ContainerInstance/containerGroups`, which the
  module does not create (the module relies on the AKS-managed VNet and does not
  provision an explicit subnet resource). New networking work is required.
- **Ingress reachability.** ACI pods get VNet IPs but behave differently behind
  nginx ingress; Service/endpoint behavior for virtual-kubelet pods is more
  limited (kube-proxy does not program ACI pods the way it does VM-node pods).
  `kubernetes.io/role`-targeted services and `kubectl exec`/`logs`/port-forward
  have historically been partial or unsupported against virtual-kubelet pods,
  which the validation script relies on for diagnostics
  (`dump_honua_rollout_diagnostics` runs `kubectl logs`/`describe`).

### Storage

- **No Azure Disk PVCs on ACI.** Virtual Nodes pods cannot mount Azure Disk
  PersistentVolumes; only Azure Files (SMB) is available for durable volumes.
  The validation postgis uses `emptyDir`, which is ephemeral on ACI, so the DB
  pod would lose data on restart and — more importantly — would certify a
  storage path no operator uses for Postgres on AKS.

### Add-ons / DaemonSets

- **DaemonSets never schedule on Virtual Nodes.** This is the decisive
  limitation, identical in spirit to EKS Fargate. The observability stack's
  `node-exporter` and any log/CNI DaemonSets simply do not exist on ACI pods.
  A validation run that "passes" with Honua on Virtual Nodes would have
  **less** coverage than the VM path while appearing green.
- **No privileged / host-path / host-network pods**, no init-container parity
  guarantees, and **no `kubectl exec`/log-streaming guarantees** against ACI
  pods — directly undermining the validation script's diagnostic dumps.
- **GPU, Windows, and many sysctls unsupported**; pod startup latency is
  higher (ACI cold start) which makes readiness-gated validation flakier.

### Observability / diagnostics

- The validation path leans on `kubectl logs --all-containers`,
  `kubectl describe pods`, and `helm test` against the Honua release. Against
  virtual-kubelet pods these are partial at best, so even the web-pod-only
  variant degrades the very signal the validation exists to produce.

## Cost notes

ACI bills per-second per container group with no VM floor, so running the
stateless Honua web pod on Virtual Nodes during a short validation could shave
some VM cost. But because a real system node pool is still mandatory (and is
where CoreDNS/metrics-server/the ACI connector run), the VM floor never goes to
zero. The marginal saving is small and is offset by ACI cold-start latency,
the delegated-subnet networking work, and Azure Files if any durable storage is
needed. Not a compelling cost case.

## Should AKS validation stay VM-backed?

Yes. The single VM-backed `system` node pool with cluster autoscaler mirrors
how Honua operators actually run AKS: Azure-Disk-backed storage option, full
DaemonSet-based observability, and reliable `kubectl exec`/logs for day-2
operations. Validation on that pool certifies the real operator experience.
Virtual Nodes is a burst/overflow primitive for stateless, opt-in workloads,
not a cluster-wide runtime, and not a validation substrate.

## Limitations / blockers (explicit list)

1. Virtual Nodes can never be the whole cluster — a real VM system node pool is
   always required, so this cannot remove VMs from validation. **Structural.**
2. DaemonSets (node-exporter, log/CNI DaemonSets) do not schedule on ACI →
   reduced, silently-green coverage. **Hard blocker for a full path.**
3. `kubectl exec`/`logs`/port-forward and Service/ingress behavior are partial
   or unsupported against virtual-kubelet pods → breaks validation diagnostics
   and nginx-ingress assumptions.
4. No Azure Disk PVCs on ACI (Azure Files only); emptyDir postgis works but
   diverges from the real operator storage model.
5. Requires a subnet delegated to `Microsoft.ContainerInstance` and the
   `aci_connector_linux` profile — neither exists in the module today.
6. Pods must explicitly opt in (nodeSelector + toleration); the Honua chart and
   postgis manifest do not, so chart/manifest overrides are required.
7. Privileged/host-network/GPU/Windows workloads and tuned sysctls are
   unsupported; ACI cold start raises readiness flakiness.

## If we ever do add it: minimal module-change sketch

Treat this as an **optional, opt-in** evaluation mode, never the default, and
scoped to running *only* the stateless Honua web Deployment on ACI:

1. Add `variable "enable_virtual_nodes" { default = false }`.
2. When `true`:
   - Add an `aci_connector_linux { subnet_name = ... }` block to
     `azurerm_kubernetes_cluster.this` (requires `network_plugin = "azure"`,
     already the default).
   - Provision a dedicated subnet delegated to
     `Microsoft.ContainerInstance/containerGroups` and pass its name in.
   - Keep the existing VM system node pool unchanged (mandatory).
3. In a dedicated `aks-virtual-nodes` validation lane (not the existing AKS
   lane), deploy the Honua web pod with the virtual-node nodeSelector +
   toleration, keep postgis + ingress + observability on the VM pool, and
   explicitly mark DaemonSet-based coverage and `kubectl exec`-based
   diagnostics as **not asserted** for the ACI pod so gaps are declared, not
   hidden.
4. Guard the lane so it is clearly labeled "limited serverless-adjacent
   coverage," never a replacement for the VM-backed certification.

Estimated effort: ~3–5 days of module + networking + validation-script work
plus a new CI lane, for a mode that certifies *less* than the existing one and
still cannot remove the VM floor.

## Follow-up

- Keep this as a documented "evaluated, deferred" decision. Revisit only if a
  real operator asks to burst Honua web pods onto ACI **and** accepts a
  reduced-diagnostic, DaemonSet-less coverage story for that mode.
- No code changes are warranted now.
