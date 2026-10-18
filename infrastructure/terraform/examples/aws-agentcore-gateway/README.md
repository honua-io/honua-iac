# Optional Honua AgentCore gateway

This opt-in Pro example defaults to disabled. It fronts an existing private
Honua MCP server; it provisions no application or database. Read the
[module contract and open qualification gates](../../modules/aws-agentcore-gateway/README.md)
before enabling it. No live deployment has been qualified by this example.

Configure identity, private-origin Lattice ARN and reviewed OpenAPI/Cedar files
through the Terraform variables. Do not place JWTs or secrets in tfvars. Keep
`enabled = false` until the concrete account, resource/cost scope and plan are
approved. Use a separately configured encrypted remote backend and the existing
exact-plan/exact-apply wrappers; there is no automatically applied cloud step.

The `gateway_binding` output is secret-free declared configuration for later
DevOps/client setup. It is not a verified handoff receipt, a caller credential or
proof that the current Honua image implements JWT workspace delegation.
