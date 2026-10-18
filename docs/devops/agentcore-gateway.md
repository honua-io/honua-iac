---
type: guide
title: "Optional Honua AgentCore gateway"
description: "IaC-owned optional Pro gateway, preserved caller authority, and explicit execution qualification gates."
tags: [aws, agentcore, mcp, security]
---
# Optional AgentCore gateway

AgentCore Gateway, Policy engine, IAM, resource policy and the Honua MCP target
belong to the optional [IaC module](../../infrastructure/terraform/modules/aws-agentcore-gateway/README.md).
The server owns Pro entitlement, tenant/RBAC, immutable workspace context and the
canonical distinct-human approval inbox. The gateway cannot turn an agent into a
human approver or replace Honua execution/reconciliation.

The new example defaults to disabled. Its
[`honua.agentcore-gateway/v1`](../../infrastructure/terraform/contracts/agentcore-gateway.v1.schema.json)
output contains configured resource IDs, issuer/audience/tenant/opaque subjects,
policy/schema hashes and the single MCP URL. It contains no credentials and is
always labelled `declared-configuration-only`. DevOps must not promote this output
to a verified install receipt merely because its JSON passes validation.

HTTP passthrough was selected because aggregated MCP targets do not offer JWT
passthrough. The proxy must preserve verifiable caller identity rather than inject
a shared API key. Proving a real audience-scoped on-behalf-of exchange is a future
alternative; client credentials are not equivalent to delegation. Honua's current
workspace authorizers/replay proofs require stored API-key authority. Canonical
JWT delegation, not a fabricated key claim, is necessary before the complete
workspace journey can qualify through this optional route.

The HTTP target uses reviewed OpenAPI and Cedar. Documentation of aggregated MCP
resources/prompts is not evidence that this proxy preserves every interaction.
Real qualification must exercise tool/argument rejection before target mutation,
caller and tenant continuity, resources/prompts, sessions/progress/cancellation,
and new-chat status recovery of a human-approved operation. Keep failures explicit
rather than switching to an unprotected target or dropping MCP capabilities.

No cloud apply or live AgentCore qualification is recorded here. See the module's
ordered qualification checklist and primary AWS references.
