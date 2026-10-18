mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_region" { defaults = { region = "us-west-2", name = "us-west-2" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/honua-agentcore-gateway-test"
    }
  }
  mock_resource "aws_bedrockagentcore_gateway" {
    defaults = {
      gateway_id  = "honua-agentcore-test123"
      gateway_arn = "arn:aws:bedrock-agentcore:us-west-2:123456789012:gateway/honua-agentcore-test123"
      gateway_url = "https://honua-agentcore-test123.gateway.bedrock-agentcore.us-west-2.amazonaws.com/mcp"
    }
  }
  mock_resource "aws_bedrockagentcore_policy_engine" {
    defaults = {
      policy_engine_id  = "honua_policy-test123456"
      policy_engine_arn = "arn:aws:bedrock-agentcore:us-west-2:123456789012:policy-engine/honua_policy-test123456"
    }
  }
}

run "disabled_creates_nothing" {
  command = plan
  assert {
    condition     = length(aws_bedrockagentcore_gateway.honua) == 0 && length(aws_iam_role.gateway) == 0 && length(aws_bedrockagentcore_policy.reviewed) == 0 && output.gateway_binding == null
    error_message = "Optional AgentCore must create no resources or misleading endpoint by default."
  }
}

run "explicit_identity_and_policy_are_required" {
  command = plan
  variables { enabled = true }
  expect_failures = [terraform_data.configuration]
}

run "private_jwt_target_preserves_caller_and_exact_policy_authority" {
  command = apply
  variables {
    enabled                                   = true
    honua_base_url                            = "https://honua.internal.example.test/honua"
    private_origin_resource_configuration_arn = "arn:aws:vpc-lattice:us-west-2:123456789012:resourceconfiguration/rcfg-test123"
    identity = {
      discovery_url  = "https://identity.example.test/.well-known/openid-configuration"
      issuer         = "https://identity.example.test"
      audience       = "honua-agents"
      required_scope = "agent:workspace"
      tenant_id      = "tenant-a"
      subjects       = ["agent-a"]
    }
    request_schema_json = file("tests/fixtures/mcp-request.openapi.json")
    cedar_policy_templates = {
      ReadSpecificLayer = "permit(principal is AgentCore::OAuthUser, action == AgentCore::Action::\"honua___POST:/mcp\", resource == AgentCore::Gateway::\"__HONUA_GATEWAY_ARN__\") when { context.input.method == \"tools/call\" && context.input.params.name == \"honua_query_features\" && context.input.params.arguments.serviceId == \"reviewed-service\" && context.input.params.arguments.layerId == 0 && context.input.params.arguments.limit <= 25 };"
    }
  }
  assert {
    condition     = aws_bedrockagentcore_gateway.honua[0].authorizer_type == "CUSTOM_JWT" && one(aws_bedrockagentcore_gateway.honua[0].policy_engine_configuration).mode == "ENFORCE"
    error_message = "No auth bypass or LOG_ONLY configuration is supported."
  }
  assert {
    condition     = length(one(aws_bedrockagentcore_gateway_target.honua[0].credential_provider_configuration).jwt_passthrough) == 1 && length(one(aws_bedrockagentcore_gateway_target.honua[0].credential_provider_configuration).api_key) == 0 && length(one(aws_bedrockagentcore_gateway_target.honua[0].credential_provider_configuration).oauth) == 0
    error_message = "The target must preserve caller JWT rather than introduce an API key or shared OAuth client."
  }
  assert {
    condition     = !strcontains(aws_bedrockagentcore_resource_policy.honua[0].policy, "InboundJwtClaim") && strcontains(one(one(aws_bedrockagentcore_policy.identity_boundary[0].definition).cedar).statement, "tenant-a") && strcontains(one(one(aws_bedrockagentcore_policy.identity_boundary[0].definition).cedar).statement, "agent-a")
    error_message = "Identity must be constrained by supported JWT/Cedar authority, never unsupported InvokeGateway IAM claim conditions."
  }
  assert {
    condition     = output.gateway_binding.mcpUrl == "https://honua-agentcore-test123.gateway.bedrock-agentcore.us-west-2.amazonaws.com/honua/mcp" && output.gateway_binding.honuaOrigin == "https://honua.internal.example.test/honua"
    error_message = "Exactly one customer MCP URL must preserve the origin PathBase without duplicating Gateway's /mcp suffix."
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.authorize[0].policy, "*") && !strcontains(aws_iam_role_policy.engine_read[0].policy, "*") && !strcontains(aws_iam_role_policy.authorize[0].policy, "GetSecretValue")
    error_message = "Execution permissions must bind exact engine/gateway ARNs and never read a shared credential."
  }
  assert {
    condition     = strcontains(one(one(aws_bedrockagentcore_policy.reviewed["ReadSpecificLayer"].definition).cedar).statement, "reviewed-service") && !strcontains(one(one(aws_bedrockagentcore_policy.reviewed["ReadSpecificLayer"].definition).cedar).statement, "__HONUA_GATEWAY_ARN__") && output.gateway_binding.qualification == "declared-configuration-only"
    error_message = "Reviewed tool arguments must survive substitution; configuration is not live execution proof."
  }
}
