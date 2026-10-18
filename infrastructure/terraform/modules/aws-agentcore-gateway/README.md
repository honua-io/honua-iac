# Optional AgentCore Gateway for Honua Pro

This module declares an optional AWS AgentCore HTTP passthrough to one existing
Honua MCP server. `enabled = false` creates nothing. Enabling it creates paid AWS
resources and requires a reviewed plan in the customer's account. It neither
installs Honua nor grants an edition entitlement: the server must verify Pro and
its actual caller authority independently.

The target uses `CUSTOM_JWT` inbound authentication, exact audience/scope and a
required `tenant_id` claim. It forwards that caller JWT unchanged with
`JWT_PASSTHROUGH`. There is no shared administrator, API key vault, anonymous
fallback, client-credentials grant or model-selected credential. The existing
Honua deployment must validate the issuer, audience, subject, tenant and delegated
agent grants. A valid human JWT must not become a workspace-agent credential.
Current API-key-only workspace/replay authorization requires a separate canonical
JWT delegation implementation before this route can qualify unified workflows.

The private origin is an existing same-account/Region VPC Lattice resource
configuration. Verify the underlying MCP listener is actually private and cannot
be bypassed through another public listener. Merely setting this ARN does not
prove that deployment-wide property. The module creates no VPC/Lattice backend
and does not change an existing application's public ingress.

The gateway has one fixed target, `honua`. Its output MCP URL is the AgentCore
origin plus `/honua/mcp` (or the explicitly selected canonical route). The target
preserves the configured Honua PathBase. Only protocol/session headers and
`X-Honua-Workspace`/`X-Honua-Turn` locators are forwarded; those locators confer no
authority. Tenant or role headers are not propagated. Tools, resources, prompts,
operation receipts and human approvals remain owned by Honua.

`request_schema_json` and `cedar_policy_templates` are reviewed Git artifacts.
Supply actual OpenAPI for the exact MCP path and its request fields. Do not copy a
generic schema and then claim arguments were checked. Cedar templates use only
one substitution, `__HONUA_GATEWAY_ARN__`, to bind the created gateway. Keep actual
tool names and argument guards in Cedar. No natural-language policy generation is
performed. A mandatory independent identity forbid prevents permits from widening
the configured subject/tenant boundary. Policy validation fails on findings and
the policy engine always uses `ENFORCE`; no permit exists by default.

IAM separates the exact engine-read permission needed at gateway creation from
runtime evaluation on the exact created gateway and engine. It grants no secret
reads or target cloud mutation. AWS requires a wildcard principal for OAuth
resource policies; this policy binds the exact gateway ARN and validated issuer,
subjects and required scope, with an explicit insecure-transport deny.

## Qualification status

The output is **declared configuration only**, never an installation or execution
receipt. Terraform mock tests inspect configuration and cannot prove AWS Policy
extracts the expected action/arguments for this HTTP target. Qualify that behavior
on a reviewed isolated target before advertising the gateway as working:

1. Verify the actual gateway, target, engine, resource policy and private-origin
   identity match these outputs. Check the effective Cedar schema/action names.
2. Invoke a permitted tool with actual caller A. Confirm Honua records caller A,
   its tenant and current grants. Wrong issuer/audience/tenant, caller B, revoked
   grant and a changed forbidden argument must fail before target mutation.
3. Verify live `tools/list`, resource/prompt list/read/get, session continuity,
   progress/SSE and cancellation. Test the actual client's protocol version;
   HTTP passthrough documentation is not a complete async-task qualification.
4. Run a real governed Honua proposal through its existing distinct human inbox,
   then status/reconciliation in a later chat. Gateway Policy cannot approve an
   operation or replace its canonical durable approval.
5. Verify direct public-origin access is refused, and retain only safe IDs,
   policy/schema digests and scrubbed outcomes. Never save JWTs in evidence.

Provider `6.61` does not contain HTTP passthrough. This module requires the actual
released AWS provider `>= 6.69.1, < 7`; the example pins `6.69.1`.

Primary contracts:

- [AWS HTTP passthrough](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-target-http-passthrough.html)
- [Inbound JWT and passthrough](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-inbound-auth.html)
- [Policy permissions](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/policy-permissions.html)
- [OAuth resource policies](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/resource-based-policies.html)
- [Header restrictions](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-headers.html)
- [Released Terraform target schema](https://github.com/hashicorp/terraform-provider-aws/blob/v6.69.1/website/docs/r/bedrockagentcore_gateway_target.html.markdown)
