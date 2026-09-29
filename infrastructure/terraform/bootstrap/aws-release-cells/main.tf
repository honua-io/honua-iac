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
    Statement = concat(jsondecode(templatefile("${path.module}/policies/${lane}.json.tftpl", local.template_vars)).Statement, local.guardrails)
  }) }
  runtime_boundary = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(jsondecode(templatefile("${path.module}/policies/runtime.json.tftpl", local.template_vars)).Statement, local.guardrails)
  })
}

resource "aws_iam_policy" "workload_boundary" {
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
  for_each = local.lane_policies
  role     = aws_iam_role.cell[each.key].id
  name     = "cell-permissions"
  policy   = each.value
}

output "role_arns" { value = { for lane, role in aws_iam_role.cell : lane => role.arn } }
output "permissions_boundary_arn" { value = aws_iam_policy.workload_boundary.arn }
output "policies" { value = local.lane_policies }
output "runtime_boundary" { value = local.runtime_boundary }
