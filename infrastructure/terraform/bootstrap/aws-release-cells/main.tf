data "aws_caller_identity" "current" {}

locals {
  boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.name}-workload-boundary"
  template_vars = {
    account_id            = data.aws_caller_identity.current.account_id
    region                = var.region
    boundary_arn          = local.boundary_arn
    mirror_repository_arn = var.mirror_repository_arn
  }
  guardrails = jsondecode(templatefile("${path.module}/policies/guardrails.json.tftpl", local.template_vars)).Statement
  lane_policies = { for lane in ["provision", "reaper", "mirror"] : lane => jsonencode({
    Version   = "2012-10-17"
    Statement = concat([for statement in jsondecode(templatefile("${path.module}/policies/${lane}.json.tftpl", local.template_vars)).Statement : statement if statement.Sid != "PassCellRoles" || var.enable_workload_role_passing], local.guardrails)
  }) }
  grant_policies = { for lane, policy in local.lane_policies : lane => jsonencode({
    Version   = "2012-10-17"
    Statement = [for statement in jsondecode(policy).Statement : statement if statement.Effect == "Allow"]
  }) }
  guardrail_policy = jsonencode({ Version = "2012-10-17", Statement = local.guardrails })
  runtime_boundary = jsonencode({
    Version = "2012-10-17"
    Statement = concat([for statement in jsondecode(templatefile("${path.module}/policies/runtime.json.tftpl", local.template_vars)).Statement :
      merge(statement, contains(["CellVpcNetworking", "CreateCellVpcNetworkInterface"], statement.Sid) ? { Condition = { ArnEquals = { "ec2:Vpc" = var.workload_vpc_arns } } } : {})
      if !contains(["CellVpcNetworking", "CreateCellVpcNetworkInterface", "NewCellNetworkInterface"], statement.Sid) || length(var.workload_vpc_arns) > 0
      ], [for statement in local.guardrails : statement if !contains(["ProtectBoundary", "NeverRemoveBoundary", "RequireBoundary", "NoRetaggingOwner", "NoStandingCreation", "NoStandingLifecycle"], statement.Sid)],
      length(var.runtime_bedrock_model_arns) == 0 ? [] : [{
        Sid      = "InvokeApprovedBedrockModels"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = var.runtime_bedrock_model_arns
      }]
    )
  })
}

resource "aws_iam_policy" "workload_boundary" {
  lifecycle {
    precondition {
      condition = alltrue([for arn, vpc in data.aws_vpc.workload :
        startswith(arn, "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:vpc/") &&
        try(vpc.tags.Owner, "") == "release-cell" &&
        length(try(vpc.tags.ValidationRunId, "")) > 0 &&
        !contains(["cert", "standing", "demo"], try(vpc.tags.Environment, "")) &&
        !contains(["standing", "demo"], try(vpc.tags.Lifecycle, ""))
      ])
      error_message = "Every networking allowlist VPC must belong to a tagged ephemeral cell in this account/region."
    }
  }
  name   = "${var.name}-workload-boundary"
  policy = local.runtime_boundary
}

resource "aws_iam_role" "cell" {
  for_each             = local.lane_policies
  name                 = "${var.name}-${each.key}"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = var.oidc_subjects[each.key]
      } }
    }]
  })
}

resource "aws_iam_role_policy" "cell" {
  for_each = local.grant_policies
  role     = aws_iam_role.cell[each.key].id
  name     = "cell-permissions"
  policy   = each.value
}

output "role_arns" { value = { for lane, role in aws_iam_role.cell : lane => role.arn } }
output "permissions_boundary_arn" { value = aws_iam_policy.workload_boundary.arn }
output "policies" { value = local.lane_policies }
output "runtime_boundary" { value = local.runtime_boundary }

resource "aws_iam_policy" "guardrails" {
  name   = "${var.name}-guardrails"
  policy = local.guardrail_policy
}
resource "aws_iam_role_policy_attachment" "guardrails" {
  for_each   = local.lane_policies
  role       = aws_iam_role.cell[each.key].name
  policy_arn = aws_iam_policy.guardrails.arn
}
data "aws_vpc" "workload" {
  for_each = var.workload_vpc_arns
  id       = split("/", each.value)[1]
}
