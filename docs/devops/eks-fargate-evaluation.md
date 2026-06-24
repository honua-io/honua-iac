# Evaluation: EKS Fargate profile support for validation

- Status: Recommendation delivered
- Date: 2026-06-24
- Tracking issue: [#11](https://github.com/honua-io/honua-iac/issues/11)
- Scope: written evaluation only; no module or workflow changes are made by
  this document.

## Summary recommendation

**Keep EC2 managed node groups as the default and only validation path. Do not
add Fargate profile support to the `aws-eks` module at this time.**

Fargate is technically reachable for *part* of the Honua validation workload,
but it cannot host the full validation scenario as it exists today, and the
partial coverage it would add does not justify the module complexity, the new
networking/storage constraints, or the loss of fidelity versus how operators
actually run Honua on EKS. The recommendation is to leave a documented,
optional follow-up (below) rather than implement now.

## What the validation path actually deploys

Grounded in the current code:

- `infrastructure/terraform/modules/aws-eks/main.tf` provisions a VPC
  (`terraform-aws-modules/vpc/aws`), an EKS control plane
  (`terraform-aws-modules/eks/aws ~> 20.0`), the `coredns`, `kube-proxy`, and
  `vpc-cni` managed add-ons, and a single `eks_managed_node_groups.default`
  group (EC2, AL2023, configurable instance types / min-max-desired).
- `infrastructure/terraform/validation/scripts/aws/run-eks-terraform-integration.sh`
  applies that module and then hands off to the shared Kubernetes path,
  `infrastructure/terraform/validation/scripts/k8s/run-k8s-terraform-integration.sh`.
- The shared k8s path installs the Honua Helm chart
  (`infrastructure/helm/honua`, sourced from the server repo) plus an
  **nginx** ingress class, and for the in-cluster database it applies
  `infrastructure/terraform/validation/scripts/k8s/k8s/postgis.yaml` — a
  single-replica `postgis/postgis:17-3.5` Deployment.
- The observability leg installs Prometheus/Grafana via the
  `observability-stack` module (`prometheus_persistence_enabled=false` in
  validation).

So the validation workload is not "one stateless web pod." It is: a web
Deployment, an ingress controller, an in-cluster stateful database, the CNI /
kube-proxy / CoreDNS add-ons, and a Prometheus/Grafana observability stack.

## Why Fargate does not fit cleanly

EKS Fargate runs each pod on a dedicated, AWS-managed microVM selected by
**Fargate profiles** (namespace + label selectors). That model collides with
several things the current validation path relies on:

### Compute model

- **No nodes, no node groups.** A Fargate-only cluster has no
  `eks_managed_node_groups`. The module's single most important input
  (`node_instance_types`, `node_min/max/desired_size`, `node_cpu_architecture`)
  becomes meaningless, and the cluster has zero capacity until at least one
  Fargate profile exists. This is a structural rewrite of the module, not a
  flag.
- **Per-pod sizing, no bursting.** Fargate sizes a microVM from the pod's CPU
  and memory *requests* and bills per pod for its lifetime. The Honua chart and
  postgis manifest do not set tuned requests/limits for a Fargate cost model,
  so pods would land on rounded-up Fargate sizes.

### Networking

- **CNI changes.** Fargate pods do not use the `vpc-cni` DaemonSet the way EC2
  nodes do; each pod gets its own ENI in a private subnet. Fargate profiles
  require **private** subnets. The module already creates private subnets, so
  that part is fine, but the `vpc-cni` add-on configuration in the module is
  written for the node-backed model.
- **Load balancing / ingress.** `nginx` ingress on Fargate cannot use a
  `NodePort` Service (there are no nodes), so it must front via an NLB in
  `ip` target mode, or be replaced by the AWS Load Balancer Controller with
  ALB ingress. The validation path currently assumes `ingress.className=nginx`.
  Making nginx work on Fargate is possible but adds an AWS-Load-Balancer-
  Controller dependency and IRSA wiring that the module does not install today.

### Storage

- **No persistent block storage.** Fargate does not support EBS-backed
  `PersistentVolumeClaims`; only EFS via the EFS CSI driver is available for
  durable storage. The validation postgis uses `emptyDir`, which *does* work on
  Fargate (ephemeral, ~20 GiB default), so the validation database itself is
  not the blocker — but this is exactly the divergence we don't want: it would
  certify a storage path (ephemeral/EFS) that no real Honua EKS operator uses
  for Postgres.

### Add-ons / DaemonSets

- **DaemonSets do not schedule on Fargate.** This is the decisive limitation.
  Anything shipped as a DaemonSet — node-exporter in the Prometheus stack, log
  shippers, the AWS VPC CNI DaemonSet, kube-proxy as a DaemonSet — will never
  run on Fargate pods. The observability leg's `node-exporter` would be
  silently absent, so a "passing" Fargate validation would have **less**
  coverage than the EC2 path while looking green. Privileged or host-network
  pods are likewise unsupported.

### Autoscaling

- Fargate has no Cluster Autoscaler / Karpenter concept; scaling is implicitly
  per-pod. The current module exposes node group min/max/desired to model
  capacity; that signal disappears, and HPA-on-Fargate behaves differently
  (cold microVM start per scaled pod).

## Cost notes

For a short-lived validation run, Fargate's per-pod-second billing can be
*cheaper* than a 1–3 node EC2 group that is provisioned for the whole run,
because there is no always-on node floor and no NAT-attached idle capacity
between pods. That is the one genuine upside the issue is chasing ("reduce
EC2-specific teardown noise"). But the saving is small at validation scale and
is offset by (a) the NLB/ALB the ingress now needs, (b) EFS if any durable
storage is required, and (c) engineering time. It is not a compelling cost
case on its own.

## Is "managed node groups" an intentional requirement?

Partly intentional, partly default. It is the *correct* default because it
mirrors how Honua operators actually run EKS (node-backed, EBS-backed Postgres
option, full DaemonSet-based observability), so validation on node groups
certifies the real operator experience. It is not a hard application
requirement of Honua itself — the server is a stateless web workload that could
run on Fargate — but the **validation scenario** (in-cluster DB + ingress
controller + node-exporter) is node-shaped.

## Blockers (explicit list)

1. DaemonSet-based components (node-exporter, CNI/log DaemonSets) cannot run on
   Fargate → reduced, silently-green validation coverage. **Hard blocker for a
   full Fargate-only path.**
2. `nginx` ingress requires re-platforming to NLB `ip`-mode or AWS Load
   Balancer Controller + IRSA. **Module work required.**
3. EBS-backed PVCs unavailable on Fargate (EFS CSI only); current emptyDir
   postgis works but diverges from the real operator storage model.
4. The module's node-group inputs (`node_instance_types`,
   `node_min/max/desired_size`, `node_cpu_architecture`) have no Fargate
   equivalent → structural module change, not an additive flag.
5. Fargate profiles require private subnets (already satisfied) and a profile
   per scheduled namespace (`honua`, `kube-system`/CoreDNS, observability).

## If we ever do add it: minimal module-change sketch

Treat this as an **optional, opt-in** mode, never the default:

1. Add `variable "compute_mode" { default = "node_group" }` accepting
   `node_group` or `fargate`.
2. When `fargate`:
   - Set `eks_managed_node_groups = {}` and instead populate the upstream
     module's `fargate_profiles` for the `honua` namespace and for `kube-system`
     (so CoreDNS schedules) plus the observability namespace.
   - Patch the `coredns` add-on to the Fargate compute type
     (`configuration_values` with the `eks.amazonaws.com/compute-type: fargate`
     annotation) and drop the `vpc-cni`/`kube-proxy` reliance assumptions.
   - Add the AWS Load Balancer Controller (Helm) + IRSA role, and switch the
     validation ingress to ALB or NLB `ip` target-type.
   - Mark observability components that are DaemonSets as **unsupported** in this
     mode (explicit `node-exporter` disable) so coverage gaps are declared, not
     hidden.
3. Guard with a `check` block asserting that `fargate` mode and any node-group
   inputs are mutually exclusive.
4. Add a dedicated `aws-eks-fargate` validation lane rather than overloading the
   existing EKS lane, so the node-backed certification remains intact.

Estimated effort: ~2–4 days of module + validation-script work plus a new CI
lane, for a mode that certifies *less* than the existing one.

## Follow-up

- Keep this as a documented "evaluated, deferred" decision. Revisit only if a
  real operator asks to run Honua server on Fargate **and** we are willing to
  certify a node-exporter-less observability story for that mode.
- No code changes are warranted now.
