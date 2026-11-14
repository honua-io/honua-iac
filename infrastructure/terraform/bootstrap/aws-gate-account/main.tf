resource "aws_organizations_account" "gate" {
  name                       = "honua-gate"
  email                      = var.account_email
  parent_id                  = var.parent_id
  role_name                  = "HonuaGateBootstrap"
  iam_user_access_to_billing = "DENY"
  close_on_deletion          = false
  lifecycle { prevent_destroy = true }
}

resource "aws_organizations_policy" "region" {
  name = "honua-gate-region"
  type = "SERVICE_CONTROL_POLICY"
  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "GateRegionOnly"
      Effect    = "Deny"
      NotAction = ["iam:*", "route53:*", "cloudfront:*"]
      Resource  = "*"
      Condition = { StringNotEquals = { "aws:RequestedRegion" = "us-east-1" } }
    }]
  })
}
resource "aws_organizations_policy_attachment" "region" {
  policy_id = aws_organizations_policy.region.id
  target_id = aws_organizations_account.gate.id
}

resource "aws_organizations_policy" "budget_fence" {
  name = "honua-gate-budget-fence"
  type = "SERVICE_CONTROL_POLICY"
  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadAndCleanupOnly"
      Effect = "Deny"
      NotAction = [
        "*:Get*", "*:List*", "*:Describe*", "*:Delete*", "*:Remove*", "*:Untag*",
        "ec2:TerminateInstances", "ec2:StopInstances", "ec2:Detach*", "ec2:Disassociate*", "ec2:ReleaseAddress", "ec2:Revoke*",
        "elasticloadbalancing:DeregisterTargets", "iam:DetachRolePolicy", "iam:PassRole",
        "ecs:DeregisterTaskDefinition", "ecs:StopTask", "batch:DeregisterJobDefinition",
        "batch:TerminateJob", "batch:CancelJob", "lambda:RemovePermission",
        "route53:ChangeResourceRecordSets", "cloudfront:UpdateDistribution", "cloudfront:UpdateFunction",
        "cloudfront:UpdateVpcOrigin", "wafv2:DisassociateWebACL", "backup:StopBackupJob",
        "sts:GetCallerIdentity"
      ]
      Resource = "*"
      }, {
      Sid       = "DnsCleanupOnly"
      Effect    = "Deny"
      Action    = "route53:ChangeResourceRecordSets"
      Resource  = "*"
      Condition = { "ForAnyValue:StringNotEquals" = { "route53:ChangeResourceRecordSetsActions" = ["DELETE"] } }
    }]
  })
}

resource "aws_budgets_budget" "gate" {
  name         = "honua-gate-monthly"
  budget_type  = "COST"
  limit_amount = "300"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_filter {
    name   = "LinkedAccount"
    values = [aws_organizations_account.gate.id]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
resource "aws_iam_role" "budget_action" {
  name = "HonuaGateBudgetAction"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "budgets.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.management_account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:budgets::${var.management_account_id}:budget/${aws_budgets_budget.gate.name}" }
      }
    }]
  })
}
resource "aws_iam_role_policy" "budget_action" {
  name = "gate-account-fence-only"
  role = aws_iam_role.budget_action.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow", Action = ["organizations:AttachPolicy", "organizations:DetachPolicy"]
      Resource = [aws_organizations_policy.budget_fence.arn, aws_organizations_account.gate.arn]
    }]
  })
}
resource "aws_budgets_budget_action" "fence" {
  budget_name        = aws_budgets_budget.gate.name
  action_type        = "APPLY_SCP_POLICY"
  approval_model     = "AUTOMATIC"
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budget_action.arn
  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = 100
  }
  definition {
    scp_action_definition {
      policy_id  = aws_organizations_policy.budget_fence.id
      target_ids = [aws_organizations_account.gate.id]
    }
  }
  subscriber {
    address           = var.budget_alert_email
    subscription_type = "EMAIL"
  }
  depends_on = [aws_iam_role_policy.budget_action, aws_organizations_policy_attachment.region]
}
output "member_account_id" {
  description = "Private input to the member stage; never paste into public PRs or logs."
  value       = aws_organizations_account.gate.id
  sensitive   = true
}
