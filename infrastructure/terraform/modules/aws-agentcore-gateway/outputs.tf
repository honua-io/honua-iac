output "gateway_binding" {
  description = "Secret-free declared AgentCore binding, not a provider-observed or execution-qualified receipt."
  value = var.enabled ? {
    schemaVersion                         = "honua.agentcore-gateway/v1"
    gatewayArn                            = aws_bedrockagentcore_gateway.honua[0].gateway_arn
    gatewayId                             = aws_bedrockagentcore_gateway.honua[0].gateway_id
    mcpUrl                                = "${regex("^https://[^/]+", aws_bedrockagentcore_gateway.honua[0].gateway_url)}/${local.target_name}${var.mcp_path}"
    honuaOrigin                           = trimsuffix(local.honua_base_url, "/")
    originPrivateResourceConfigurationArn = local.private_origin_arn
    policyEngineArn                       = aws_bedrockagentcore_policy_engine.honua[0].policy_engine_arn
    policyMode                            = "ENFORCE"
    inboundAuth                           = "CUSTOM_JWT"
    outboundAuth                          = "JWT_PASSTHROUGH"
    identity                              = local.identity
    requestSchemaSha256                   = sha256(local.schema_json)
    policyTemplateSha256                  = { for name, statement in var.cedar_policy_templates : name => sha256(statement) }
    entitlementRequired                   = "pro"
    qualification                         = "declared-configuration-only"
  } : null
}
