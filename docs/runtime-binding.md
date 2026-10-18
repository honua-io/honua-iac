# Runtime identity for agent handoff

`runtime_binding_contract` is a credential-free projection of resources in an
applied Terraform root. Its schema is
[`honua.runtime-binding/v1`](../infrastructure/terraform/contracts/runtime-binding.v1.schema.json).
The Lambda module and `examples/aws-serverless` emit it. The schema also defines
ECS and EKS identities; their producer and workload integration remain pending.

The Lambda projection records the named alias's serving version, which may differ
from the latest published function version. It identifies the proxy route, API
integration and alias encoded in that integration's URI. It contains resource
identifiers, not passwords, connection strings or credentials.

The DevOps consumer must match these facts to the host-selected runtime, server
deployment target and environment. It must then independently read the actual
provider resources, verify the route and alias, and retain observation evidence.
Terraform output alone proves neither current reachability nor deployment and
rollback qualification. An absent or malformed projection cannot produce a
verified handoff.

The existing EKS root provisions infrastructure, database and workload identity
configuration. The EKS workflow requires the native
`honua-kubernetes-deployment` backend, with no Argo installation, controller,
CRD or API dependency. Its current generic GitOps output is not sufficient.
The actual Honua Deployment, Service, public route and bound Kubernetes cluster
identity must be installed and independently verified before handoff. Honua
approvals and durable operations govern upgrades, health checks and rollback
to the recorded prior immutable image digest. The schema's EKS branch does not
assert that those resources or the complete workflow currently exist.
