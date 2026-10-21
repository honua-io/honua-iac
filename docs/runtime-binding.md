---
type: reference
title: "Runtime identity for agent handoff"
description: "Credential-free Terraform resource identity and the independent verification required before agent handoff."
resource: "https://github.com/honua-io/honua-iac/blob/trunk/infrastructure/terraform/contracts/runtime-binding.v1.schema.json"
tags: [contract, operator, identity]
---
# Runtime identity for agent handoff

`runtime_binding_contract` is a credential-free projection of resources in an
applied Terraform root. Its schema is
[`honua.runtime-binding/v1`](../infrastructure/terraform/contracts/runtime-binding.v1.schema.json).
The Lambda module and `examples/aws-serverless` emit it. The accepted
`examples/aws-eks-native` root also emits the EKS branch, including its
configured Deployment, Service, route, certificate, distinct server and GP
Pod Identity bindings, and Secrets Manager **ARNs**. These are locators, never
secret values. The schema defines an ECS identity, but its producer remains
pending.

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

The `examples/aws-eks` root provisions infrastructure, database and workload
identity configuration; `examples/aws-eks-native` installs the workload and
emits its configured binding. The binding names the native
`honua-kubernetes-deployment` backend, with no Argo installation, controller,
CRD or API dependency. Current honua-server builds do not register a backend
by that name. Their Kubernetes backends are `honua-gitops-kubernetes` and
`honua-kubernetes-argo-rollouts`. The honua-helm chart registers
`honua-gitops-kubernetes` as `ControlPlane__DeployTargets__0__Backend`; it is
a GitOps passthrough that cannot roll back by itself. Until the native backend
ships (honua-iac#267), the EKS binding is a forward declaration: a Helm
install registers `honua-gitops-kubernetes` and recovers with `helm rollback`.
The actual Honua Deployment, Service, public route and bound Kubernetes
cluster identity must be independently verified after apply before handoff.
Once the native backend is available, Honua approvals and durable operations
govern upgrades, health checks and rollback to the recorded prior immutable
image digest. The schema's EKS branch does not
assert live health, a verified provider observation or a qualified agent
handoff; that end-to-end evidence remains outstanding.

The Lambda module writes its deployment registry to a managed Secrets Manager
settings document. Each function environment references a specific document
version through `HONUA_SETTINGS_DOCUMENT`, keeping the full function ARN,
explicit region and alias outside Lambda's 4 KB environment budget. The API and
scheduled functions receive read permission on that exact secret. Use a Honua
image that supports the settings-document startup loader; earlier images cannot
consume this module's registry. Retain the referenced secret versions for the
function versions kept as rollback targets. Rolling back a function version
therefore selects its pinned configuration, subject to that version remaining
available. The module reserves `HONUA_SETTINGS_DOCUMENT`, `Settings__Document`
and the complete `ControlPlane:DeployTargets` configuration tree. Because
environment settings take precedence over the document, `additional_env` cannot
retarget or append deployments, including through case or separator variants.
Unrelated environment overrides remain available. The agent must still verify
the effective registry against independent provider observations.
