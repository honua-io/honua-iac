# Ephemeral PR Gate runners on the lane build host. Everything here is absent unless
# gate_runner_enabled is true.

locals {
  gate_runner_count = var.gate_runner_enabled ? 1 : 0
  gate_runner_host_config = {
    region              = var.region
    org                 = split("/", var.gate_runner_repository)[0]
    group               = "honua-server-gate"
    labels              = ["self-hosted", "linux", "x64", "honua-build"]
    runner_count        = var.gate_runner_count
    cpu_quota_percent   = var.gate_runner_cpu_quota_percent
    memory_max_gib      = var.gate_runner_memory_max_gib
    runner_version      = "2.338.2"
    runner_sha256       = "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40"
    app_parameter       = "/${local.name}/gate-runner/github-app"
    heartbeat_parameter = "/${local.name}/gate-runner/heartbeat"
  }
  github_oidc_host = "token.actions.githubusercontent.com"
}

# The founder writes {"app_id": ..., "private_key": ...} here; Terraform never holds the value.
resource "aws_ssm_parameter" "gate_runner_app" {
  count       = local.gate_runner_count
  name        = local.gate_runner_host_config.app_parameter
  description = "GitHub App credential that mints single-job runner registrations; readable only by the build host root services."
  type        = "SecureString"
  value       = "unset"
  tags        = local.tags
  lifecycle { ignore_changes = [value] }
}

# The host reports its instance and idle runner count; the PR Gate reads it to choose compute.
resource "aws_ssm_parameter" "gate_runner_heartbeat" {
  count       = local.gate_runner_count
  name        = local.gate_runner_host_config.heartbeat_parameter
  description = "Build host gate runner readiness: instance, epoch seconds and idle runners."
  type        = "String"
  value       = "{}"
  tags        = local.tags
  lifecycle { ignore_changes = [value] }
}

resource "aws_iam_role_policy" "gate_runner_host" {
  count = local.gate_runner_count
  name  = "gate-runner-registration"
  role  = aws_iam_role.build.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ssm:GetParameter", Resource = aws_ssm_parameter.gate_runner_app[0].arn },
      { Effect = "Allow", Action = "ssm:PutParameter", Resource = aws_ssm_parameter.gate_runner_heartbeat[0].arn }
    ]
  })
}

data "aws_iam_openid_connect_provider" "github" {
  count = local.gate_runner_count
  url   = "https://${local.github_oidc_host}"
}

resource "aws_iam_role" "gate_runner_wake" {
  count                = local.gate_runner_count
  name_prefix          = "${local.name}-wake-"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github[0].arn }
      Condition = {
        StringEquals = {
          "${local.github_oidc_host}:aud" = "sts.amazonaws.com"
          "${local.github_oidc_host}:sub" = "repo:${var.gate_runner_repository}:pull_request"
        }
      }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "gate_runner_wake" {
  count = local.gate_runner_count
  name  = "wake-build-host"
  role  = aws_iam_role.gate_runner_wake[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # DescribeAutoScalingGroups has no resource-level permissions.
      { Effect = "Allow", Action = "autoscaling:DescribeAutoScalingGroups", Resource = "*" },
      { Effect = "Allow", Action = "autoscaling:SetDesiredCapacity", Resource = aws_autoscaling_group.build.arn },
      { Effect = "Allow", Action = "ssm:GetParameter", Resource = aws_ssm_parameter.gate_runner_heartbeat[0].arn }
    ]
  })
}
