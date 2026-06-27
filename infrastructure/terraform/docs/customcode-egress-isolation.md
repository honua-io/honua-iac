# Custom-code GP egress isolation (two-phase + CodeArtifact)

> Module: `modules/aws-serverless` · Flag: `enable_customcode_egress_isolation`
> (default `false`) · Requires `enable_gp_batch = true`.

## Why

The MVP GP-over-Batch path (`batch.tf`, security group
`aws_security_group.batch`) runs **dependency restore** (pip/git → PyPI/GitHub)
**and the user's custom code in ONE Fargate task** whose egress security group
allows `443` to `0.0.0.0/0` ("ECR, Secrets Manager, S3, CloudWatch"). That coarse
allowlist is fine for first-party GP, but for **custom-code** jobs it means user
code can exfiltrate to any host on the open internet under the cover of
"restoring dependencies". There is no point in the task lifecycle where the
egress posture tightens.

This hardening (gated, off by default) splits the two concerns into **two
separate Batch jobs** with two different egress postures, and routes dependency
restore through an **AWS CodeArtifact pull-through cache** reached over VPC
endpoints instead of the public internet.

## Chosen architecture — separate provisioning job → cached layer → locked-down execution job

```
                ┌─────────────────────────────────────────────────────────┐
                │ VPC (private subnets, no NAT default route needed)        │
                │                                                           │
  PROVISIONING  │   ┌───────────────┐   443   ┌──────────────────────────┐ │
  Batch job ────┼──▶│ batch_         │────────▶│ customcode_endpoints SG  │ │
  (restore)     │   │ provisioning   │         │  • codeartifact.api      │ │
                │   │ SG             │   S3 PL  │  • codeartifact.repos    │ │
                │   │  + tight       │────────▶│  • sts                   │ │
                │   │  GitHub CIDRs  │         │  • secretsmanager        │ │
                │   └───────┬───────┘          └──────────────────────────┘ │
                │           │ writes dependency layer                       │
                │           ▼                  ┌──────────────┐ (gateway)    │
                │     ┌───────────┐   S3 PL    │ S3 endpoint  │              │
  EXECUTION     │     │ artifact  │◀──────────▶│ (assets +    │              │
  Batch job ────┼────▶│ bucket    │            │  artifact    │              │
  (user code)   │     │ prefix    │            │  bucket)     │              │
                │   ┌───────────────┐          └──────────────┘              │
                │   │ batch_        │   443                                  │
                │   │ execution SG  │────────▶ customcode_endpoints SG only  │
                │   │ NO PyPI/      │   S3 PL ▶ artifact bucket only         │
                │   │ GitHub/0.0.0.0│   5432  ▶ VPC (DB)                      │
                │   └───────────────┘                                        │
                └─────────────────────────────────────────────────────────┘
```

1. **Provisioning job** (`aws_batch_job_definition.gp_provisioning`, compute env
   `aws_batch_compute_environment.gp_provisioning`, queue
   `aws_batch_job_queue.gp_provisioning`) restores dependencies through the
   CodeArtifact pull-through repos and writes the resolved **dependency layer** to
   the S3 artifact-bucket prefix. Its SG (`aws_security_group.batch_provisioning`)
   is where dependency egress lives.
2. **Execution job** runs the user's custom code under
   `aws_security_group.batch_execution` (compute env
   `aws_batch_compute_environment.gp_execution`, queue
   `aws_batch_job_queue.gp_execution`) with **no dependency-registry or
   open-internet egress** — it only reaches the in-VPC endpoints and the artifact
   bucket (to consume the layer the provisioning job wrote).

### Why two *separate jobs* (not one task that switches SG mid-run)

A Fargate task has **exactly one ENI and one security-group set for its entire
lifetime**. There is no API to swap an SG part-way through a task. So the only way
to give "restore" a looser egress posture than "run user code" is to run them as
**two separate Fargate tasks/jobs on two compute environments**, each pinned to
its own SG. This is the architectural reason for the two job definitions, two
compute environments, and two queues.

## What egress each phase has

| Phase | 443 to CodeArtifact/STS/Secrets endpoints | S3 gateway (artifact bucket) | GitHub | Open internet (`0.0.0.0/0`) | 5432 (DB) |
|-------|:--:|:--:|:--:|:--:|:--:|
| **Provisioning** | yes | yes | tight allowlist (`customcode_github_egress_cidrs`, empty ⇒ none) | **no** | yes |
| **Execution** | yes (Secrets/STS only) | yes | **no** | **no** | yes |

The two SGs egress `443` to the dedicated endpoint SG
(`aws_security_group.customcode_endpoints`) and to the S3 gateway endpoint's
managed **prefix list** — there is no `0.0.0.0/0` rule on either phase.

## CodeArtifact pull-through wiring

- `aws_codeartifact_domain.customcode` — the domain
  (`var.customcode_codeartifact_domain_name`, default `honua-customcode`).
- `aws_codeartifact_repository.pypi` — external connection `public:pypi`.
- `aws_codeartifact_repository.nuget` — external connection `public:nuget-org`.
- VPC endpoints: `aws_vpc_endpoint.codeartifact_api`,
  `aws_vpc_endpoint.codeartifact_repositories` (interface, private DNS),
  `aws_vpc_endpoint.customcode_sts`, `aws_vpc_endpoint.customcode_secretsmanager`
  (interface), and `aws_vpc_endpoint.customcode_s3` (gateway; CodeArtifact serves
  assets from S3, and the artifact-bucket handoff rides the same prefix list).
- IAM: `aws_iam_role_policy.batch_job_codeartifact` grants the GP job role
  `codeartifact:GetAuthorizationToken` (domain-scoped),
  `codeartifact:GetRepositoryEndpoint` + `codeartifact:ReadFromRepository`
  (repo-scoped), and `sts:GetServiceBearerToken` **conditioned** on
  `sts:AWSServiceName = codeartifact.amazonaws.com`. No `Action = "*"`; resources
  are ARN-scoped (the policy gate forbids wildcard actions).

The provisioning job-def passes `HONUA_CODEARTIFACT_*` env (domain, owner, repo
names, region) so the worker's restore step points pip/nuget at the CodeArtifact
endpoints instead of public registries.

## Residual risks (honest)

1. **GitHub egress is still required for git-sourced deps.** An internal git
   mirror is **not implemented**. If a manifest pins a git SHA, the provisioning
   phase must reach GitHub — `customcode_github_egress_cidrs` is the boundary.
   Empty default ⇒ no GitHub reach; a non-empty list is a CIDR allowlist (GitHub
   publishes ranges at `https://api.github.com/meta`), which is IP-coarse, not
   host/path-scoped, and GitHub's ranges change over time.
2. **S3 gateway egress is bucket-coarse, not object-scoped.** The prefix-list
   egress + IAM permit the bucket; SG-level filtering cannot scope to a key
   prefix. Object-level isolation would need a bucket policy / per-object grant
   (deferred).
3. **The provisioning job can still exfil via the registry during restore if the
   user controls the manifest.** The CodeArtifact pull-through cache + SHA-pin
   *mitigate* (packages flow through a cache you can audit/pin, not arbitrary
   hosts) but do **not eliminate** the channel — a malicious package fetched
   during restore still runs in the provisioning phase. An egress proxy with
   domain/package allowlisting is the stronger control (deferred).
4. **No in-task phase switch ⇒ the orchestrator is the trust boundary.** Nothing
   in Terraform forces the user-code job onto the execution queue/SG. If the
   server's reconciler submits user code to the *provisioning* queue, isolation is
   defeated. The two-phase separation is only as strong as the orchestrator
   correctly running the execution job under the locked-down SG. (Recommend an
   assertion in the reconciler + a guardrail that the execution job-def is the
   only one allowed to run user manifests.)
5. **DNS / metadata-endpoint considerations.** DNS resolution still occurs
   (private DNS for the endpoints; the VPC resolver at the `.2` address). A
   determined exfiltration channel could attempt DNS tunneling — not blocked by L3
   SG rules. The ECS task metadata endpoint (`169.254.170.2`) and the IMDS link-
   local range are reachable from the task regardless of SG; the execution job
   relies on the scoped task role (no CodeArtifact grant on the execution path).

## Deferred (explicitly not in this change)

- Internal git mirror (removes GitHub egress from provisioning).
- Egress proxy with domain/package-name filtering (replaces IP allowlists).
- Per-object S3 bucket policy scoping (object-level isolation).
- Reconciler-side enforcement that user manifests only ever run on the execution
  queue (the orchestration trust-boundary guardrail).

## Enabling

```hcl
module "honua" {
  source = "../../modules/aws-serverless"
  # ...
  enable_gp_batch                    = true
  enable_customcode_egress_isolation = true
  customcode_codeartifact_domain_name = "honua-customcode"
  # Only if git-sourced deps are needed (else leave empty for no GitHub egress):
  # customcode_github_egress_cidrs = ["140.82.112.0/20", "143.55.64.0/20"]
}
```

`examples/aws-cert/main.tf` wires the flag (set to `false`) as the reference
instantiation.
