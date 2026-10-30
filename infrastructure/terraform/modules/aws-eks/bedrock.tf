# Bedrock invoke for the EKS server workload role. Off unless enable_bedrock_ai.
# Same ARN construction as modules/aws-ecs: the account-scoped inference profile in
# bedrock_ai_region, plus the foundation model in each US member region. The GP job
# role is not granted invoke. The default model stays the shipped Sonnet 4.6 profile.
locals {
  bedrock_ai_enabled = var.enable_bedrock_ai

  bedrock_foundation_model_id = replace(var.bedrock_ai_model, "/^[a-z]{2}\\./", "")

  # Destinations of the us. profiles read with GetInferenceProfile: us-east-1, us-east-2, us-west-2.
  bedrock_inference_member_regions = ["us-east-1", "us-east-2", "us-west-2"]

  bedrock_invoke_resources = !local.bedrock_ai_enabled ? [] : startswith(var.bedrock_ai_model, "us.") ? concat(
    ["arn:aws:bedrock:${var.bedrock_ai_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_ai_model}"],
    [for region in local.bedrock_inference_member_regions : "arn:aws:bedrock:${region}::foundation-model/${local.bedrock_foundation_model_id}"]
  ) : ["arn:aws:bedrock:${var.bedrock_ai_region}::foundation-model/${var.bedrock_ai_model}"]

  # honua-server refuses a Studio model call without an exact disclosure approval.
  # Enabling Bedrock here is that approval for the one configured model.
  bedrock_ai_environment = local.bedrock_ai_enabled ? {
    AiExecutionAdmission__DeploymentId                          = local.name
    StudioAiProxy__Disclosure__WorkloadDataClassification       = var.bedrock_ai_data_classification
    StudioAiProxy__Disclosure__Approvals__0__Provider           = "bedrock"
    StudioAiProxy__Disclosure__Approvals__0__Kind               = "bedrock"
    StudioAiProxy__Disclosure__Approvals__0__Destination        = "aws-bedrock:${var.bedrock_ai_region}"
    StudioAiProxy__Disclosure__Approvals__0__Model              = var.bedrock_ai_model
    StudioAiProxy__Disclosure__Approvals__0__UseCase            = "studio-chat"
    StudioAiProxy__Disclosure__Approvals__0__DataClassification = var.bedrock_ai_data_classification
    StudioAiProxy__Enabled                                      = "true"
    StudioAiProxy__DefaultProvider                              = "bedrock"
    StudioAiProxy__Providers__bedrock__Kind                     = "bedrock"
    StudioAiProxy__Providers__bedrock__Model                    = var.bedrock_ai_model
    StudioAiProxy__Providers__bedrock__Region                   = var.bedrock_ai_region
    StudioAiProxy__Providers__bedrock__MaxTokens                = tostring(var.bedrock_ai_max_tokens)
    StudioAiProxy__Providers__bedrock__TimeoutSeconds           = tostring(var.bedrock_ai_timeout_seconds)
    WorkflowGeneration__Enabled                                 = "true"
    WorkflowGeneration__DefaultProvider                         = "bedrock"
    WorkflowGeneration__Providers__bedrock__Model               = var.bedrock_ai_model
    WorkflowGeneration__Providers__bedrock__Region              = var.bedrock_ai_region
    WorkflowGeneration__Providers__bedrock__MaxTokens           = tostring(var.bedrock_ai_max_tokens)
    WorkflowGeneration__Providers__bedrock__TimeoutSeconds      = tostring(var.bedrock_ai_timeout_seconds)
  } : {}
}

resource "aws_iam_role_policy" "server_bedrock_invoke" {
  count = local.bedrock_ai_enabled ? 1 : 0

  name = "${local.name}-server-bedrock"
  # .name is the role name PutRolePolicy requires, and it is known at plan.
  # .id is the same string after apply but stays unknown until then.
  role = aws_iam_role.workload["server"].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "InvokeBedrockModel"
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
      ]
      Resource = compact(local.bedrock_invoke_resources)
    }]
  })
}
