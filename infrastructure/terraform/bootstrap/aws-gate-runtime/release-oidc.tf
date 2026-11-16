data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "release_actions" {
  name                 = "HonuaGateReleaseActions"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:honua-io/honua-release:environment:gate"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "release_actions" {
  name = "assume-gate-lane-only"
  role = aws_iam_role.release_actions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = aws_iam_role.lane.arn
    }]
  })
}

output "release_actions_role_arn" {
  value       = aws_iam_role.release_actions.arn
  sensitive   = true
  description = "Authenticated release producer entry point; may only assume the gate lane role."
}
