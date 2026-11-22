# AWS CI OIDC roles

This root replaces long-lived AWS access keys held as repository secrets
(readable from a workflow on any branch) with GitHub OIDC roles. Each role
trusts one exact environment subject, with audience `sts.amazonaws.com`, a
no certification policy, and a two-hour session for the Bedrock roles (one hour for the inventory roles). It does not create the OIDC
provider or any access key.

| Key | Repository and workflow | Environment | Role | Grant |
| --- | --- | --- | --- | --- |
| `bedrock-smoke` | honua-server `ci.yml` (mcp-llm-smoke) | `bedrock-smoke` | `honua-server-gha-bedrock-smoke` | invoke Anthropic models |
| `bedrock-eval` | honua-sdk-js `mcp-eval-live.yml` | `bedrock-eval` | `honua-sdk-js-gha-bedrock-eval` | invoke Anthropic and Amazon Nova models |
| `bedrock-console` | honua-console `console-live-llm-nightly.yml` | `bedrock-live-llm` | `honua-console-gha-bedrock-live-llm` | invoke Anthropic models |
| `inventory-plan` | honua-iac `release-cell-inventory-policy.yml` (plan) | `cell-inventory-plan` | `honua-iac-gha-cell-inventory-plan` | read the release role's inline policy |
| `inventory-apply` | honua-iac `release-cell-inventory-policy.yml` (deploy) | `cell-inventory-apply` | `honua-iac-gha-cell-inventory-apply` | read and write the release role's inline policy |
| `launch-stack-publish` | honua-marketplace `publish-launch-stack.yml` | `launch-stack-publish` | `honua-marketplace-gha-launch-stack-publish` | create (conditional write) and read `templates/*` in the Launch Stack hosting bucket |

The Bedrock grant is `bedrock:InvokeModel` and
`bedrock:InvokeModelWithResponseStream` on the role's model-ID prefixes
(`anthropic.`, plus `amazon.nova-` for the sdk-js eval), as foundation models
and as this account's `us.` inference profiles, in `bedrock_regions` (default
us-east-1, us-east-2, us-west-1 and us-west-2, where the US profiles route).
The publish role exists only when `launch_stack_template_bucket` names the
bucket created by honua-marketplace `template-hosting.yaml`. It may create
objects under `templates/` only with a conditional write, which the bucket policy
also demands, and read them back to confirm a retried upload; it has no delete,
Object Lock bypass or bucket policy rights, so a published version stays
immutable. Its environment needs a required reviewer and trunk as the only
deployment branch, plus the variables `LAUNCH_STACK_TEMPLATE_BUCKET`,
`LAUNCH_STACK_TEMPLATE_REGION` and `LAUNCH_STACK_PUBLISH_ROLE_ARN` (the
`role_arns` output).
The inventory grants are limited to `inventory_role_name` (default
`honua-release-cicd`). The inventory environments are used by
`release-cell-inventory-policy.yml` alone (configured via
`HONUA_AWS_CELL_INVENTORY_PLAN_ROLE_ARN` and
`HONUA_AWS_CELL_INVENTORY_APPLY_ROLE_ARN`): the shared `terraform-ephemeral`
and `terraform-live-approval` environments also run manual validation and the
hosted-pilot bootstrap, whose approved jobs must not be able to rewrite the
release role's policy.

## Order

1. Create the GitHub environments: `bedrock-smoke` (honua-server),
   `bedrock-eval` (honua-sdk-js), `bedrock-live-llm` (honua-console),
   `cell-inventory-plan` (honua-iac, trunk only) and `cell-inventory-apply`
   (honua-iac, trunk only, required reviewer). Apply this root (main; new
   roles only, nothing imported).
2. Each consumer declares its `environment:` on the job and switches
   `aws-actions/configure-aws-credentials` from the key secrets to
   `role-to-assume` with the `role_arns` output, plus `id-token: write`. A job
   without the environment presents a ref or pull_request subject and is
   refused. Anything handed static credentials (the console LiteLLM sidecar)
   must also receive `AWS_SESSION_TOKEN`.
3. Delete the repository key secrets (honua-server `BEDROCK_AWS_*` and the
   unused `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`; honua-iac
   `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`) and deactivate the IAM user keys
   behind them.

Applied 18 November 2026 (environments trunk-only, admin bypass off;
`cell-inventory-apply` has a required reviewer). The root is `"applied": true`
in `../drift-roots.json`, so the bootstrap drift plan reads it.

## State

Remote, at `bootstrap/aws-ci-oidc-roles/terraform.tfstate`
(`backend.tf.example`; copy it to the gitignored `backend.tf`).

## Tests

`terraform test` renders the trusts and grants with the real provider and fake
credentials; nothing reaches AWS.
