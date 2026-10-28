###############################################################################
# Amazon Bedrock access for the Honua AI studio (workflow / dashboard / report
# generation).
#
# The server's WorkflowGeneration "bedrock" provider calls the Bedrock Converse
# API as a Microsoft.Extensions.AI IChatClient, authenticating via the AWS
# credential chain — i.e. the Lambda execution role. Without an explicit
# bedrock:InvokeModel grant the AI console gets AccessDenied, so this is gated
# on enable_bedrock_ai (default false) and scoped least-privilege to the single
# Claude model the server is configured to use.
#
# Cross-region inference: the default model id is the `us.` inference profile
# (us.anthropic.claude-sonnet-4-5-...). Invoking through an inference profile
# requires BOTH the inference-profile ARN (in the calling region) AND the
# underlying foundation-model ARNs in every member region the profile routes to
# (us-east-1 / us-east-2 / us-west-2). Granting only the profile yields
# AccessDenied on the foundation model; granting only the foundation model
# yields AccessDenied on the profile.
#
# Toggled off by default so existing deploys are unchanged unless an operator
# opts in.
###############################################################################

locals {
  bedrock_ai_enabled = var.enable_bedrock_ai

  # The `us.` (or other geo) prefix denotes a cross-region inference profile;
  # the underlying foundation model id is the same id with that prefix stripped.
  bedrock_foundation_model_id = replace(
    var.bedrock_ai_model,
    "/^[a-z]{2}\\./",
    ""
  )

  # Member regions a `us.` cross-region inference profile can route the request
  # to. The foundation-model ARN must be granted in each so a routed invocation
  # is authorized regardless of which region Bedrock dispatches to.
  bedrock_inference_member_regions = ["us-east-1", "us-east-2", "us-west-2"]

  # Resource ARNs for the InvokeModel grant:
  #   1. The inference-profile ARN in the region the server calls
  #      (var.bedrock_ai_region) — account-scoped.
  #   2. The foundation-model ARNs (account-agnostic) in each member region.
  bedrock_invoke_resources = !local.bedrock_ai_enabled ? [] : startswith(var.bedrock_ai_model, "us.") ? concat(
    ["arn:aws:bedrock:${var.bedrock_ai_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_ai_model}"],
    [for region in local.bedrock_inference_member_regions : "arn:aws:bedrock:${region}::foundation-model/${local.bedrock_foundation_model_id}"]
  ) : ["arn:aws:bedrock:${var.bedrock_ai_region}::foundation-model/${var.bedrock_ai_model}"]

  # StudioAiProxy env that routes the AI studio flows to Bedrock.
  #
  # Lambda environment budget (main.tf lambda_environment_bytes): only settings
  # the server reads, and only where they differ from its defaults.
  # - WorkflowGeneration:* is not emitted: honua-server removed the
  #   provider-backed planner and its WorkflowGeneration options (ADR-0076,
  #   #3255; AiBuilderServiceCollectionExtensions), so nothing reads them.
  # - MaxTokens/TimeoutSeconds are emitted only when they differ from the
  #   StudioAiProxy provider defaults (4096 / 120 s, StudioAiProxyConfiguration).
  # - Region is emitted only when it is not us-west-2: an empty Region falls
  #   back to the adapter's fixed DefaultBedrockRegion "us-west-2"
  #   (BedrockChatClientAdapter), not to the function's region.
  # Kind, DefaultProvider and Model stay explicit: they have no default and
  # startup validation fails without them.
  bedrock_ai_environment = local.bedrock_ai_enabled ? merge({
    StudioAiProxy__Enabled                   = "true"
    StudioAiProxy__DefaultProvider           = "bedrock"
    StudioAiProxy__Providers__bedrock__Kind  = "bedrock"
    StudioAiProxy__Providers__bedrock__Model = var.bedrock_ai_model
    },
    var.bedrock_ai_region != "us-west-2" ? { StudioAiProxy__Providers__bedrock__Region = var.bedrock_ai_region } : {},
    var.bedrock_ai_max_tokens != 4096 ? { StudioAiProxy__Providers__bedrock__MaxTokens = tostring(var.bedrock_ai_max_tokens) } : {},
    var.bedrock_ai_timeout_seconds != 120 ? { StudioAiProxy__Providers__bedrock__TimeoutSeconds = tostring(var.bedrock_ai_timeout_seconds) } : {},
  ) : {}
}

# Least-privilege Bedrock invoke grant on the Lambda execution role, scoped to
# the configured Claude model's inference-profile + foundation-model ARNs.
resource "aws_iam_role_policy" "lambda_bedrock_invoke" {
  count = local.bedrock_ai_enabled ? 1 : 0
  name  = "${local.name}-lambda-bedrock"
  role  = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeBedrockClaudeModel"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = compact(local.bedrock_invoke_resources)
      }
    ]
  })
}
