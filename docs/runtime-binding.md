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
configuration. Its generic GitOps backend is not an Argo Rollouts installation.
An EKS application handoff still requires the actual controller, Rollout, Service,
public route and Kubernetes connection identity to be installed and verified.
The schema's EKS branch does not assert that those resources currently exist.
