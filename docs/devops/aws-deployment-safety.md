---
type: guide
title: "Configure AWS deployment safety"
description: "Wire the native ECS recovery controller, validate its prerequisites, and bind installed settings to candidate recovery evidence."
tags: [aws, ecs, deployment, recovery]
---
# AWS deployment safety and recovery prerequisites

Release promise: **2026.1 safe rollout must have executable protection and
verified recovery before the platform RC** (honua-release#319, honua-iac#182).
This is the installation handoff to the existing Honua controller and target
capability API. It does not introduce another reconciler or qualify a cloud
installation using Terraform mocks.

## Select the topology

The default SingleInstance service stops its old task before starting the new
one. Its startup circuit breaker lives in the AWS control plane, but cannot
recover a first deployment without a previous `COMPLETED` revision. The duration
of interruption is unbounded. It has no configured functional/metric recovery
window.

Native post-activation safety uses stable and candidate ECS services in
MultiNode mode with Redis and shared S3. It adds an ALB weighted rule at priority
50000 for the canonical `honua-aws-ecs-alb` backend. The existing higher-priority
candidate header rule remains available for validation. The controller owns
weights after installation; Terraform ignores subsequent changes to this
rule's actions. Do not apply a new infrastructure/candidate change while an
operation owns the target lease. Review a plan before disabling this profile:
removing it removes the controller-owned rule and its IAM policy, exposing the
listener's configured default weights again.

Use an **existing retained controller outside both workload services**, with its
own durable operation store, leases, approved policy and telemetry credentials.
A different IAM role alone does not prove a surviving controller process. The
module looks up that role and refuses the candidate task/execution role. It
attaches ECS canary-service update/describe and ALB rule mutation permissions;
read APIs without resource-level authorization use `Resource = "*"`. Candidate
tasks receive no rollout mutation permissions. Existing workload task S3 and
execution-role secret/KMS/log permissions remain separate.

## Configure and register

In `examples/aws`, set the existing typed MultiNode, Redis, S3 and canary inputs
and supply digest-pinned `honua_image` and `canary_image`. Configure this optional
object in your untracked tfvars:

```hcl
deployment_safety = {
  controller_role_name       = "honua-retained-controller"
  telemetry_connection_id    = "production-prometheus"
  prometheus_canary_job      = "production-honua-canary"
  functional_probe_url       = "https://candidate.example.com/known-fixture"
  functional_expected_sha256 = "<sha256 of independently specified response bytes>"
  observation_window_seconds = 600
  recovery_timeout_seconds   = 300
  warmup_seconds             = 180
  evidence_grace_seconds     = 120
  max_staleness_seconds      = 60
  exposure_deadline_seconds  = 900
}
```

The functional URL must reach the candidate independently of normal weighted
traffic. Establish an expected result from a known seeded dataset, including
values/geometry/ordinates/nodata/metadata where applicable; never bless whatever
the current candidate happens to return. The Prometheus connection is registered
on the retained controller and the job must scrape only this candidate cell.
The `aws-alb-canary` runtime preset consumes Honua Prometheus metrics, **not** the
`AWS/ApplicationELB` namespace. The latter is only a provider metric source.

After a governed exact-plan apply, capture and validate:

```bash
terraform -chdir=infrastructure/terraform/examples/aws output -json > installed.json
./scripts/validate-operator-contract.sh --require-qualified installed.json
```

Read `operations_contract.resilience.protection_profile.execution` from the
output. Register its `target_id`, `target_kind`, `backend_name` and `parameters`
through the existing target API and select the exact task definition ARN as the
desired revision. Preserve the parameter map unchanged in the approved deploy
operation. Fetch target capabilities and require rollback, progress polling,
revision pinning and traffic shifting for `honua-aws-ecs-alb`. The handoff gives
the controller the installed cluster, canary service, traffic rule and distinct
stable/canary target groups; do not substitute listener ARNs or another cell.

The emitted keys use the canonical runtime vocabulary:

| Input | Runtime parameter | Valid whole seconds |
| --- | --- | --- |
| Observation window | `deployment.protection.observation_window_seconds` | 1–86400 |
| Recovery deadline | `deployment.rollback.observation_timeout_seconds` | 1–1800 |
| Warmup | `telemetry.warmup_seconds` | 1–21600 |
| Missing-evidence grace | `telemetry.evidence_grace_seconds` | 1–3600 |
| Maximum metric age | `telemetry.max_staleness_seconds` | 1–3600 |
| Exposure deadline | `telemetry.exposure_deadline_seconds` | 1–7200 |

Terraform rejects malformed settings. These are runtime budgets, not a promise
that recovery succeeds by a deadline. Failed or unavailable recovery must retain
the server's unavailable/manual-intervention outcome. Pin a server implementing
honua-server#4617/#4618; an older runtime that ignores parameters is not qualified.

## Validate access and controller survival

Before advertising protection, #118 must demonstrate on the installed topology:

1. Both tasks ready; managed **or external** Redis reachable; artifact written by
   one task readable after replacement by another through the configured S3
   bucket. Local file storage is not shared state.
2. Workload role positive access to the configured bucket and negative access to
   an unrelated bucket; execution-role positive reads of exact configured
   secrets/keys and negative access to unrelated ones. Include restrictive
   bucket/resource policies and KMS grants: an attached IAM allow cannot override
   a resource-policy deny. External S3 CMKs require operator-managed grants; this
   module does not infer them from a bucket name.
3. The retained controller can read its telemetry connection and candidate-only
   samples; unauthorized, absent and stale telemetry must fail the runtime gate.
   Readiness alone and successful CloudWatch logging are insufficient.
4. Distinct real A/B Honua images under traffic, functional and telemetry failure
   injection, candidate unable to boot, and candidate/controller task replacement.
   Prove the retained controller survives and can restore the intended identity,
   ALB weights, reads, writes, authentication and persisted data. Exercise no
   usable prior revision and restored-but-unhealthy failures and measure recovery
   against the configured deadline.
5. Preserve the prior task definition **and** image/config/secret versions and
   compatible data until observation or verified recovery completes. `skip_destroy`
   retains definitions across replacement/teardown; it does not stop ECR lifecycle
   deletion, secret rotation, data migration or manual deregistration.

## Bind the live evidence

The live #118 run and honua-release#321 candidate recovery certificate must
reference the same immutable evidence bundle. Capture:

- The exact `installed.json` and `operator_contract_digest`; candidate/manifest,
  IaC revision, provider-lock, backend and image digests; account/region and
  state lineage/serial from its shared identity block.
- The registered target, returned target capabilities, exact execution parameter
  map and controller identity/topology. Hash the installed contract bytes and
  retain the canonical contract digest as well; they are different hashes.
- The approved operation/policy digest, prior/candidate task-definition and image
  identities, AWS describe responses and runtime observation/recovery receipts.
- Immutable CI artifact URLs/digests for readiness, independent functional
  assertions, identity/storage/telemetry positive and negative probes, timestamps,
  controller survival, final data-plane verification and teardown.

Compare every binding to the candidate lock and installed target; reject a
substituted account, region, task/image, policy, contract digest or stale receipt.
Use the existing release certificate validator for the exact candidate. This
runbook is not a new receipt schema or a manually assertable `protected` flag.
The Terraform contract deliberately stays `unverified`; only the runtime and
joined release certificate may attest protected/recovered outcomes.

The live-provider/candidate-certificate criterion remains owned by #118/#321:
#182 prohibits provisioning billable infrastructure as backlog implementation.
Static tests here cannot release the live gate or manufacture a certificate.
Lambda's separate 2026.1 qualification remains honua-release#282; no Lambda
recovery claim is added. Azure #147 remains 2027.

## Implementation validation (2026-09-13)

The #182 implementation was checked locally with 28 passing ECS module runs,
three passing operator-root runs, and canonical schema/digest/identity validation
of all three applied root outputs. The operator-contract suite passed 21 checks,
including 28 native safety assertions with independently specified duration,
identity and SHA-256 expectations. Terraform validation, recursive formatting,
and the strict policy gate (including TFLint and Checkov) passed. Provider tests
use Terraform mocks and are not live AWS/candidate recovery evidence.
