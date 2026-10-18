data "aws_caller_identity" "current" { count = var.enabled ? 1 : 0 }
data "aws_region" "current" { count = var.enabled ? 1 : 0 }
data "aws_partition" "current" { count = var.enabled ? 1 : 0 }

locals {
  identity = var.identity == null ? {
    discovery_url  = "https://configuration.invalid/.well-known/openid-configuration"
    issuer         = "https://configuration.invalid"
    audience       = "unconfigured"
    required_scope = "unconfigured"
    tenant_id      = "unconfigured"
    subjects       = toset(["unconfigured"])
  } : var.identity
  honua_base_url     = coalesce(var.honua_base_url, "https://configuration.invalid")
  schema_json        = coalesce(var.request_schema_json, "{}")
  private_origin_arn = coalesce(var.private_origin_resource_configuration_arn, "arn:aws:vpc-lattice:us-west-2:000000000000:resourceconfiguration/rcfg-unconfigured")
  target_name        = "honua"
  region             = var.enabled ? data.aws_region.current[0].region : ""
  account            = var.enabled ? data.aws_caller_identity.current[0].account_id : ""
  partition          = var.enabled ? data.aws_partition.current[0].partition : "aws"
}

resource "terraform_data" "configuration" {
  count = var.enabled ? 1 : 0
  lifecycle {
    precondition {
      condition     = var.honua_base_url != null && var.identity != null && var.private_origin_resource_configuration_arn != null && var.request_schema_json != null && length(var.cedar_policy_templates) > 0
      error_message = "Enabled AgentCore requires an existing private Honua origin, explicit identity, reviewed OpenAPI and Cedar policies."
    }
    precondition {
      condition     = var.private_origin_resource_configuration_arn == null ? false : startswith(var.private_origin_resource_configuration_arn, "arn:${local.partition}:vpc-lattice:${local.region}:${local.account}:resourceconfiguration/")
      error_message = "The private origin resource configuration must belong to this account and Region."
    }
    precondition {
      condition     = var.request_schema_json == null ? false : try(length(keys(jsondecode(var.request_schema_json).paths)) == 1 && contains(keys(jsondecode(var.request_schema_json).paths), var.mcp_path) && contains(keys(jsondecode(var.request_schema_json).paths[var.mcp_path]), "post"), false)
      error_message = "The reviewed OpenAPI must describe only the exact selected MCP path, including POST."
    }
  }
}

resource "aws_bedrockagentcore_policy_engine" "honua" {
  count       = var.enabled ? 1 : 0
  name        = "${replace(var.name, "-", "_")}_policy"
  description = "Additional Honua agent tool/argument controls; canonical Honua authorization and human approval remain authoritative."
  tags        = var.tags
  depends_on  = [terraform_data.configuration]
}

resource "aws_iam_role" "gateway" {
  count = var.enabled ? 1 : 0
  name  = "${var.name}-gateway"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account }
        ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account}:gateway/*" }
      }
    }]
  })
  tags       = var.tags
  depends_on = [terraform_data.configuration]
}

# Gateway creation validates GetPolicyEngine using its execution role. Grant only
# that exact engine before creation; grant runtime evaluation on exact ARNs later.
resource "aws_iam_role_policy" "engine_read" {
  count = var.enabled ? 1 : 0
  role  = aws_iam_role.gateway[0].id
  name  = "read-exact-policy-engine"
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "bedrock-agentcore:GetPolicyEngine", Resource = aws_bedrockagentcore_policy_engine.honua[0].policy_engine_arn }]
  })
}

resource "aws_bedrockagentcore_gateway" "honua" {
  count           = var.enabled ? 1 : 0
  name            = var.name
  role_arn        = aws_iam_role.gateway[0].arn
  authorizer_type = "CUSTOM_JWT"
  # No protocol_type: HTTP passthrough preserves the existing MCP protocol.
  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url    = local.identity.discovery_url
      allowed_audience = [local.identity.audience]
      allowed_scopes   = [local.identity.required_scope]
      custom_claim {
        inbound_token_claim_name       = "tenant_id"
        inbound_token_claim_value_type = "STRING"
        authorizing_claim_match_value {
          claim_match_operator = "EQUALS"
          claim_match_value { match_value_string = local.identity.tenant_id }
        }
      }
    }
  }
  policy_engine_configuration {
    arn  = aws_bedrockagentcore_policy_engine.honua[0].policy_engine_arn
    mode = "ENFORCE"
  }
  tags       = var.tags
  depends_on = [aws_iam_role_policy.engine_read]
}

resource "aws_iam_role_policy" "authorize" {
  count = var.enabled ? 1 : 0
  role  = aws_iam_role.gateway[0].id
  name  = "authorize-exact-gateway-and-engine"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["bedrock-agentcore:AuthorizeAction", "bedrock-agentcore:PartiallyAuthorizeActions"]
      Resource = [aws_bedrockagentcore_gateway.honua[0].gateway_arn, aws_bedrockagentcore_policy_engine.honua[0].policy_engine_arn]
    }]
  })
}

resource "aws_bedrockagentcore_resource_policy" "honua" {
  count        = var.enabled ? 1 : 0
  resource_arn = aws_bedrockagentcore_gateway.honua[0].gateway_arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AuthenticatedOAuthInvocation"
        Effect    = "Allow"
        Principal = "*" # Required by AWS for OAuth; authorizer + mandatory Cedar constrain identity.
        Action    = "bedrock-agentcore:InvokeGateway"
        Resource  = aws_bedrockagentcore_gateway.honua[0].gateway_arn

      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "bedrock-agentcore:InvokeGateway"
        Resource  = aws_bedrockagentcore_gateway.honua[0].gateway_arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

resource "aws_bedrockagentcore_gateway_target" "honua" {
  count              = var.enabled ? 1 : 0
  gateway_identifier = aws_bedrockagentcore_gateway.honua[0].gateway_id
  name               = local.target_name
  target_configuration {
    http {
      passthrough {
        endpoint      = trimsuffix(local.honua_base_url, "/")
        protocol_type = "MCP"
        schema {
          source {
            inline_payload { payload = local.schema_json }
          }
        }
      }
    }
  }
  credential_provider_configuration {
    jwt_passthrough {}
  }
  private_endpoint {
    self_managed_lattice_resource {
      resource_configuration_identifier = local.private_origin_arn
    }
  }
  metadata_configuration {
    allowed_request_headers  = ["Mcp-Session-Id", "MCP-Protocol-Version", "Last-Event-ID", "X-Honua-Workspace", "X-Honua-Turn"]
    allowed_response_headers = ["Mcp-Session-Id", "MCP-Protocol-Version"]
  }
  depends_on = [aws_iam_role_policy.authorize, aws_bedrockagentcore_resource_policy.honua]
}

# This mandatory forbid is independent of reviewed permits: no permit can widen
# the configured tenant/subject boundary. It creates no Honua administrative role.
resource "aws_bedrockagentcore_policy" "identity_boundary" {
  count            = var.enabled ? 1 : 0
  name             = "HonuaIdentityBoundary"
  policy_engine_id = aws_bedrockagentcore_policy_engine.honua[0].policy_engine_id
  validation_mode  = "FAIL_ON_ANY_FINDINGS"
  definition {
    cedar {
      statement = <<-CEDAR
        forbid (principal, action, resource == AgentCore::Gateway::"${aws_bedrockagentcore_gateway.honua[0].gateway_arn}")
        unless {
          principal is AgentCore::OAuthUser &&
          ${jsonencode(sort(tolist(local.identity.subjects)))}.contains(principal.id) &&
          principal.hasTag("tenant_id") && principal.getTag("tenant_id") == ${jsonencode(local.identity.tenant_id)}
        };
      CEDAR
    }
  }
  depends_on = [aws_bedrockagentcore_gateway_target.honua]
}

resource "aws_bedrockagentcore_policy" "reviewed" {
  for_each         = var.enabled ? var.cedar_policy_templates : {}
  name             = each.key
  policy_engine_id = aws_bedrockagentcore_policy_engine.honua[0].policy_engine_id
  validation_mode  = "FAIL_ON_ANY_FINDINGS"
  definition {
    cedar {
      statement = replace(each.value, "__HONUA_GATEWAY_ARN__", aws_bedrockagentcore_gateway.honua[0].gateway_arn)
    }
  }
  depends_on = [aws_bedrockagentcore_policy.identity_boundary]
}
