# Native Honua EKS workload install

This root installs the digest-pinned Honua server in an **existing** EKS cluster.
The separate `examples/aws-eks` root creates the VPC, cluster, database,
Secrets Manager references, IAM workload roles and Pod Identity associations.
Keeping the native install in a second root lets Terraform plan Kubernetes
objects against a cluster that already exists. Both roots use the governed
saved-plan/apply lineage; no chart, Argo controller or detached `kubectl` write
is part of this install.

The exact Terraform plan creates a Namespace, distinct server and GP Job
ServiceAccounts, namespace-scoped Job RBAC for the server, a server Deployment,
a public TLS LoadBalancer Service, and optionally a Route53 A alias pointed at
the Service load balancer. The server container and configured GP Job image must
both be pinned by OCI SHA-256 digest. `artifact_capabilities` must match those
digests and declare the selected workload identity mode. The image capability
assertion must come from a reviewed artifact manifest; Terraform cannot inspect
the image's compiled credential providers.

The server image must declare a numeric non-root user. The Deployment enforces
non-root execution, the default seccomp profile, no privilege escalation and
no added Linux capabilities, and always pulls the digest-pinned image.

The required inputs are the existing cluster name, environment, target and
tenant IDs, immutable images, artifact capabilities, separate server/GP role
ARNs and existing Pod Identity association IDs, database/admin/master-key and Redis secret ARNs, a public hostname and its validated ACM
certificate ARN, and an explicit load balancer controller choice. Pass the
values exposed by the existing `examples/aws-eks` outputs, using the **same**
account, region and namespace. Redis is required because GP workers need the
durable job store. Optional key-ring and audit-chain inputs are secret ARNs
only. The native root builds the server's fixed
`aws:secretsmanager:` environment references; do not pass secret values.

The `load_balancer_controller` input is required. `legacy-service-controller`
uses the EKS built-in Service controller's NLB annotation; `aws-load-balancer-controller`
uses its `external` / `ip` annotations and requires that controller to be
installed already. The root does not install a controller or assume EKS Auto
Mode. The plan runner must have Kubernetes API access and the AWS CLI for the
Kubernetes provider's short-lived EKS token exec. The selected EKS identity
must be authorized for Kubernetes writes; no node-role fallback is attempted.

This native install supports only EKS Pod Identity. The server's built-in
`aws:secretsmanager:` resolver requires its container credential endpoint and
projected authorization token, and rejects IRSA credentials. The root reads
both existing associations through the EKS API and checks their namespace,
service account and role binding, plus the active Pod Identity agent add-on,
before it plans the Deployment. It creates no IRSA annotations. The DevOps
verifier must reread those associations and observe the selected provider in
the running pod before binding a handoff.

The GP worker imports a Kubernetes Secret containing only AWS secret references
for the database, Redis, encryption master key and optional secret channel.
Its Pod Identity role can read only those secret ARNs; it has no admin-password
or audit-key permission. The Server permits operator-owned workload/default
image and service-account overrides; ordinary GP submissions cannot set the
reserved `k8s.*` request metadata. This install configures defaults but does
not prove an executed GP Job used them. That claim requires observation of the
actual Job image, service account and Pod Identity association.

`route53_zone_id` is optional. When set, Terraform owns an A alias from
`public_hostname` to the Service load balancer. The root observes one active
NLB with the Service hostname, selected controller's cluster/service tags,
Honua target tag, and the selected TLS listener certificate before creating
the alias. It also reads the exact Route53 hosted-zone ID and refuses a private
zone or a hostname outside that zone. The output describes
configured state; the verifier must still observe the live route.
With externally managed DNS, Terraform can configure the Service and
certificate, but cannot prove the external hostname points at it. The DevOps
verifier must read fresh cluster,
Deployment, Service, load balancer and DNS facts, run public readiness and
identity/MCP checks, and reauthorize the current principal, tenant and target
before a handoff binds. Terraform outputs never claim a current workload UID,
resource version, serving digest, observed public route or live readiness.

The `runtime_binding_contract` output uses
`honua.runtime-binding/v1` with the configured EKS ARN/API/CA DER SHA-256,
namespace, Deployment/container, Service ports and route. It is explicitly
configured identity, not a live observation. `deployment_contract`,
`validation_contract`, `operations_contract` and `operator_contract_digest`
use `honua.operator-contract/v2` and carry only secret references. Their
identity status remains `unqualified`: Terraform cannot certify its own
post-apply state serial. The exact executor receipt records the actual
post-apply lineage, serial, backend digest and output contract digest; a
consumer must bind that receipt to current provider observations before a
qualified runtime handoff is possible. Caller-provided pins cannot substitute
for that evidence.

Copy `backend.tf.example` to `backend.tf`, fill in the existing encrypted state
bucket and an exclusive key, then use the repository's exact-plan and
exact-apply wrappers under the separately authorized deployment role. Do not
run a plain Terraform apply for a governed install. AgentCore is optional and
has no role in this root.
