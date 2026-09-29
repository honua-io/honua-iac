---
type: reference
title: "AWS certification image and identity inputs"
description: "Digest pins, Bedrock configuration, OIDC roles and the evidence required for AWS certification."
---
# AWS certification image and identity inputs

The release promise behind #207 is a real-model Studio journey and a two-revision
upgrade/rollback on the GA ECS and Lambda substrates, using the same immutable
bytes throughout qualification. These inputs do not themselves prove live serving.

## Images

Every ECS and Lambda module image must be `registry/repository@sha256:<64 lowercase
hex>`. Tags (including release tags), bare repositories and malformed digests fail
Terraform input validation. This also covers canary, GP Batch, custom-code and
control-plane event images. Custom-code execution needs explicit Python and .NET
worker pins; creating an empty ECR repository is not an image selection.

`terraform-manual-validation.yml` accepts:

| Dispatch input | Repository/environment fallback |
|---|---|
| `aws_ecs_image` | `HONUA_AWS_ECS_IMAGE` |
| `aws_ecs_previous_image` | `HONUA_AWS_ECS_PREVIOUS_IMAGE` |
| `aws_serverless_image` | `HONUA_AWS_SERVERLESS_IMAGE` |
| `aws_serverless_previous_image` | `HONUA_AWS_SERVERLESS_PREVIOUS_IMAGE` |

Lambda pins must refer to ECR images suitable for Lambda's selected architecture.
The upgrade path requires two **different digests**, even when repository names
differ. `--aot` no longer rewrites an image reference: select the AOT artifact
before pinning it. The EKS validation entrypoint applies the same digest check.
The optional standing ALB health fixture needs `ecs_alb_image` pinned to an image
serving HTTP on port 80; it no longer falls back to nginx's mutable stable tag.

The ECS harness deploys N-1, N, then N-1, and checks serving after each transition.
The Lambda harness publishes N while retaining the N-1 alias, then passes the
old/new version IDs to the server's deploy/rollback validation suite. A Terraform
plan or hermetic orchestration test is not a live upgrade/rollback receipt.

## Bedrock

Both ECS and Lambda use `enable_bedrock_ai`, `bedrock_ai_model`,
`bedrock_ai_region`, `bedrock_ai_max_tokens`, and `bedrock_ai_timeout_seconds`.
The manual AWS lane enables Bedrock and selects the certification region.

The rendered server section is `StudioAiProxy` (Kind and DefaultProvider
`bedrock`), alongside the existing `WorkflowGeneration` configuration. Credentials
come from the ECS task or Lambda execution role. `additional_env` cannot replace
the selected model/region after the IAM grant is generated.

A foundation-model ID grants only that model in the selected region. A versioned
`us.anthropic.*` profile grants that exact profile and its pinned foundation model
in us-east-1, us-east-2 and us-west-2. Wildcards and arbitrary model ARNs are refused.
The runtime permissions boundary must also allow those exact model ARNs; a role
policy cannot override a restrictive boundary. The #208 staged boundary has not
yet been qualified with this journey. Regional endpoint connectivity and account
model access must be qualified in the live cell.

## OIDC rollout

No certification workflow reads static AWS key secrets or mints IAM users/access
keys. The operator must provision exact-subject OIDC roles and set:

| Variable | Purpose / session duration |
|---|---|
| `HONUA_AWS_VALIDATION_ROLE_ARN` | ECS/Lambda validation, 4 hours |
| `HONUA_AWS_EKS_VALIDATION_ROLE_ARN` | EKS validation, 4 hours |
| `HONUA_AWS_DRIFT_ROLE_ARN` | Read-only drift plans, 4 hours |
| `HONUA_AWS_VALIDATION_REAPER_ROLE_ARN` | Fresh session for teardown and scheduled infra sweep, 2 hours |
| `HONUA_AWS_VALIDATION_IAM_SWEEPER_ROLE_ARN` | Legacy orphan IAM cleanup only, 2 hours |

Role maximum session duration must permit the requested lifetime. Live role trust
must match the selected `terraform-ephemeral` / `terraform-live-approval` GitHub
environment; drift and scheduled jobs use their exact authorized workflow ref.
Protect environments and keep the teardown identity separate. Do not point these
variables at the partially qualified #208 staging roles without completing their
caller/tag/policy migration. Missing roles fail, with no static-key fallback.
The scheduled IAM sweeper remains to remove historical leaks; new runs create no
per-run bootstrap users.

## Evidence and remaining criteria

Local evidence on 2026-09-29: ECS and Lambda mock-provider tests assert actual task
and Lambda environment values and exact IAM actions/resources; AWS IAM simulation
allows the selected model and denies another model plus model administration
(`docs/evidence/207/`). Shell fixtures reject malformed/mutable pins and exercise
the actual ECS orchestration's N-1/N/N-1 plan and serving-check sequence. Workflow
contract tests and actionlint verify OIDC wiring.

The repository variable inspection found no configured `*_PREVIOUS_IMAGE` or
validation `*_ROLE_ARN` variables. No live cell was applied. Live StudioAi success
and populated-database upgrade/rollback remain outstanding pre-cut criteria; these
are not waived by the policy simulator. A final exact-candidate repetition belongs
to the release qualification lane, but the pre-cut rehearsal still needs approved
N-1/N artifact selections and operator-provisioned OIDC identities.
