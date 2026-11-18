# GitHub OIDC roles that replace long-lived AWS access keys held as repository
# secrets (readable from any branch's workflow).
#
# Every role trusts one exact environment subject, built with
# components/aws-github-oidc (existing provider, StringEquals, certification
# policy off, 1-hour session). A job presents the environment subject only when
# it declares `environment:`, so each consumer must declare its environment
# before it switches from the key to `role-to-assume`.
#
#   bedrock-smoke   honua-server ci.yml mcp-llm-smoke        environment bedrock-smoke
#   bedrock-eval    honua-sdk-js mcp-eval-live.yml           environment bedrock-eval
#   bedrock-console honua-console console-live-llm-nightly   environment bedrock-live-llm
#   inventory-plan  honua-iac release-cell-inventory-policy  environment cell-inventory-plan
#   inventory-apply honua-iac release-cell-inventory-policy  environment cell-inventory-apply
#   launch-stack-publish honua-marketplace publish-launch-stack environment launch-stack-publish
#
# The Bedrock roles may only invoke the model families their workflow selects
# (Anthropic; the sdk-js eval also Amazon Nova), directly or through the US
# inference profiles, with a two-hour session. The inventory roles may only
# read (plan) or read and write (apply) the inline policies of the one release
# role, and each trusts an environment used by that workflow alone, so another
# honua-iac job approved in a shared environment cannot assume them.
# The Launch Stack publish role exists only once launch_stack_template_bucket
# names the hosting bucket; it may only create objects under templates/ there
# (conditional writes, which the bucket policy also demands) and read them back
# to confirm a retried upload. It has no delete, retention bypass or policy
# rights, so a published version stays immutable.

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  roles = merge({
    bedrock-smoke = {
      repository  = "honua-server"
      environment = "bedrock-smoke"
      role_name   = "honua-server-gha-bedrock-smoke"
      kind        = "bedrock"
      models      = ["anthropic."]
    }
    bedrock-eval = {
      repository  = "honua-sdk-js"
      environment = "bedrock-eval"
      role_name   = "honua-sdk-js-gha-bedrock-eval"
      kind        = "bedrock"
      models      = ["anthropic.", "amazon.nova-"]
    }
    bedrock-console = {
      repository  = "honua-console"
      environment = "bedrock-live-llm"
      role_name   = "honua-console-gha-bedrock-live-llm"
      kind        = "bedrock"
      models      = ["anthropic."]
    }
    inventory-plan = {
      repository  = "honua-iac"
      environment = "cell-inventory-plan"
      role_name   = "honua-iac-gha-cell-inventory-plan"
      kind        = "inventory-read"
      models      = []
    }
    inventory-apply = {
      repository  = "honua-iac"
      environment = "cell-inventory-apply"
      role_name   = "honua-iac-gha-cell-inventory-apply"
      kind        = "inventory-write"
      models      = []
    }
    }, var.launch_stack_template_bucket == null ? {} : {
    launch-stack-publish = {
      repository  = "honua-marketplace"
      environment = "launch-stack-publish"
      role_name   = "honua-marketplace-gha-launch-stack-publish"
      kind        = "template-publish"
      models      = []
    }
  })

  inventory_role_arn = "arn:aws:iam::${local.account_id}:role/${var.inventory_role_name}"
  template_objects   = "arn:aws:s3:::${coalesce(var.launch_stack_template_bucket, "unset")}/templates/*"

  # One statement per Bedrock role: the model-ID prefixes its workflow selects,
  # as foundation models and as this account's US inference profiles.
  bedrock_statements = {
    for key, role in local.roles : key => {
      Sid    = "InvokeSelectedModels"
      Effect = "Allow"
      Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
      Resource = flatten([
        for family in role.models : [
          for region in var.bedrock_regions : [
            "arn:aws:bedrock:${region}::foundation-model/${family}*",
            "arn:aws:bedrock:${region}:${local.account_id}:inference-profile/us.${family}*",
          ]
        ]
      ])
    } if role.kind == "bedrock"
  }

  policies = {
    inventory-read = [{
      Sid      = "ReadReleaseRoleInlinePolicy"
      Effect   = "Allow"
      Action   = ["iam:GetRolePolicy"]
      Resource = [local.inventory_role_arn]
    }]
    inventory-write = [{
      Sid      = "ApplyReleaseRoleInlinePolicy"
      Effect   = "Allow"
      Action   = ["iam:GetRolePolicy", "iam:PutRolePolicy"]
      Resource = [local.inventory_role_arn]
    }]
    template-publish = [{
      Sid       = "CreateTemplateObjectsOnly"
      Effect    = "Allow"
      Action    = ["s3:PutObject"]
      Resource  = [local.template_objects]
      Condition = { Null = { "s3:if-none-match" = "false" } }
      }, {
      Sid      = "ReadBackRetriedTemplateObjects"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = [local.template_objects]
    }]
  }
}

module "oidc" {
  source   = "../../components/aws-github-oidc"
  for_each = local.roles

  create_oidc_provider       = false
  existing_oidc_provider_arn = var.oidc_provider_arn

  github_owner             = "honua-io"
  github_repository        = each.value.repository
  github_oidc_subjects     = ["repo:honua-io/${each.value.repository}:environment:${each.value.environment}"]
  role_name                = each.value.role_name
  cert_permissions_enabled = false
  # Eval and live-LLM runs can outlast one hour; inventory runs take minutes.
  max_session_duration_seconds = each.value.kind == "bedrock" ? 7200 : 3600

  name_prefix = each.value.repository
  environment = each.value.environment
  purpose     = "ci-${each.key}"
  tags        = { Owner = "honua-platform" }
}

resource "aws_iam_role_policy" "grant" {
  for_each = local.roles

  name = each.key
  role = module.oidc[each.key].role_name
  # Encoded per branch: the statement lists differ in length, which a conditional cannot unify.
  policy = each.value.kind == "bedrock" ? jsonencode({
    Version   = "2012-10-17"
    Statement = [local.bedrock_statements[each.key]]
    }) : jsonencode({
    Version   = "2012-10-17"
    Statement = local.policies[each.value.kind]
  })
}
