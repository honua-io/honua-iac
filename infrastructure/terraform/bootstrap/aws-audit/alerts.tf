locals {
  forwarding_regions = setsubtract(var.recorded_regions, [var.home_region])
  home_bus_arn       = "arn:${local.partition}:events:${var.home_region}:${local.account_id}:event-bus/default"

  # Calls made by Terraform, by CloudFormation, or by an AWS service on our behalf (its user agent,
  # or a service-linked role session) are IaC or automation, not a hand change. A user agent can be forged: this is a change alert, and
  # CloudTrail stays the record.
  automation_user_agents = [
    "*Terraform/*",
    "cloudformation.amazonaws.com",
    "autoscaling.amazonaws.com",
    "*application-autoscaling.amazonaws.com",
    "ecs.amazonaws.com",
    "elasticloadbalancing.amazonaws.com",
    "spot.amazonaws.com",
  ]
  name_prefixes = ["Create", "Delete", "Update", "Put", "Add", "Remove", "Publish", "Tag", "Untag"]

  # Configuration changes only. Start, stop, scaling and invalidation calls are how the hosts and
  # pools run every day, and the heartbeat parameters are written every minute.
  change_pattern = {
    source        = ["aws.ec2", "aws.autoscaling", "aws.iam", "aws.s3", "aws.cloudfront", "aws.wafv2", "aws.ecs", "aws.rds", "aws.ssm", "aws.lambda"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      userAgent    = [{ "anything-but" = { wildcard = local.automation_user_agents } }]
      userIdentity = { arn = [{ "anything-but" = { wildcard = "*:assumed-role/AWSServiceRoleFor*" } }, { exists = false }] }
      "$or" = [
        {
          eventSource = ["ec2.amazonaws.com"]
          eventName = [
            "RunInstances", "TerminateInstances", "ModifyInstanceAttribute", "ModifyInstanceMetadataOptions",
            "AssociateIamInstanceProfile", "ReplaceIamInstanceProfileAssociation",
            "CreateSecurityGroup", "DeleteSecurityGroup", "ModifySecurityGroupRules",
            "AuthorizeSecurityGroupIngress", "AuthorizeSecurityGroupEgress",
            "RevokeSecurityGroupIngress", "RevokeSecurityGroupEgress",
            "CreateVpc", "DeleteVpc", "ModifyVpcAttribute", "CreateSubnet", "DeleteSubnet", "ModifySubnetAttribute",
            "CreateRoute", "DeleteRoute", "ReplaceRoute", "AttachInternetGateway", "DetachInternetGateway",
            "AllocateAddress", "ReleaseAddress", "AssociateAddress", "DisassociateAddress",
            "CreateLaunchTemplate", "CreateLaunchTemplateVersion", "ModifyLaunchTemplate", "DeleteLaunchTemplate",
            "CreateTags", "DeleteTags",
          ]
        },
        {
          eventSource = ["autoscaling.amazonaws.com"]
          eventName = [
            "CreateAutoScalingGroup", "UpdateAutoScalingGroup", "DeleteAutoScalingGroup",
            "PutScalingPolicy", "DeletePolicy", "PutScheduledUpdateGroupAction", "DeleteScheduledAction",
            "PutLifecycleHook", "DeleteLifecycleHook", "StartInstanceRefresh",
            "AttachInstances", "DetachInstances", "SuspendProcesses", "ResumeProcesses",
            "CreateOrUpdateTags", "DeleteTags",
          ]
        },
        { eventSource = ["iam.amazonaws.com"], eventName = [{ "anything-but" = { wildcard = ["Generate*", "CreateServiceLinkedRole"] } }] },
        {
          eventSource = ["s3.amazonaws.com"]
          eventName = [
            "CreateBucket", "DeleteBucket", "PutBucketPolicy", "DeleteBucketPolicy", "PutBucketAcl",
            "PutBucketPublicAccessBlock", "DeleteBucketPublicAccessBlock", "PutBucketOwnershipControls",
            "PutBucketEncryption", "DeleteBucketEncryption", "PutBucketVersioning",
            "PutBucketLifecycle", "DeleteBucketLifecycle", "PutBucketReplication", "DeleteBucketReplication",
          ]
        },
        {
          eventSource = ["cloudfront.amazonaws.com"]
          eventName   = [{ "anything-but" = ["CreateInvalidation", "CreateInvalidationForDistributionTenant"] }]
        },
        { eventSource = ["wafv2.amazonaws.com"] },
        {
          eventSource = ["ecs.amazonaws.com"]
          eventName = [
            "CreateCluster", "UpdateCluster", "UpdateClusterSettings", "DeleteCluster", "PutClusterCapacityProviders",
            "CreateService", "UpdateService", "DeleteService",
            "RegisterTaskDefinition", "DeregisterTaskDefinition", "DeleteTaskDefinitions",
            "CreateCapacityProvider", "UpdateCapacityProvider", "DeleteCapacityProvider",
            "PutAccountSetting", "TagResource", "UntagResource",
          ]
        },
        {
          eventSource = ["rds.amazonaws.com"]
          eventName = [
            { prefix = "Create" }, { prefix = "Delete" }, { prefix = "Modify" }, { prefix = "Restore" },
            "AddTagsToResource", "RemoveTagsFromResource", "AddRoleToDBInstance", "RemoveRoleFromDBInstance",
          ]
        },
        { eventSource = ["lambda.amazonaws.com"], eventName = [for p in local.name_prefixes : { prefix = p }] },
        {
          eventSource       = ["ssm.amazonaws.com"]
          eventName         = ["PutParameter", "DeleteParameter"]
          requestParameters = { name = [{ "anything-but" = { suffix = "/heartbeat" } }] }
        },
        {
          eventSource = ["ssm.amazonaws.com"]
          eventName   = ["DeleteParameters", "LabelParameterVersion", "AddTagsToResource", "RemoveTagsFromResource"]
        },
      ]
    }
  }

  stack_drift_pattern = {
    source        = ["aws.config"]
    "detail-type" = ["Config Rules Compliance Change"]
    detail = {
      configRuleName      = ["cloudformation-stack-drift-detection-check"]
      newEvaluationResult = { complianceType = ["NON_COMPLIANT"] }
    }
  }

  alert_rules = {
    "${local.name}-manual-change" = local.change_pattern
    "${local.name}-stack-drift"   = local.stack_drift_pattern
  }
  regional_alert_rules = {
    for pair in setproduct(keys(local.alert_rules), var.recorded_regions) : "${pair[1]}/${pair[0]}" => {
      region  = pair[1]
      name    = pair[0]
      pattern = local.alert_rules[pair[0]]
    }
  }
}

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [for key, rule in local.regional_alert_rules : aws_cloudwatch_event_rule.alert[key].arn if rule.region == var.home_region]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

# Events land on the default bus of the Region where they happen (global services in us-east-1).
# Other Regions forward matches to the home bus, where the same rules publish to one topic.
resource "aws_cloudwatch_event_rule" "alert" {
  for_each      = local.regional_alert_rules
  region        = each.value.region
  name          = each.value.name
  event_pattern = jsonencode(each.value.pattern)
}

resource "aws_cloudwatch_event_target" "to_topic" {
  for_each = { for key, rule in local.regional_alert_rules : key => rule if rule.region == var.home_region }
  region   = var.home_region
  rule     = aws_cloudwatch_event_rule.alert[each.key].name
  arn      = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      time    = "$.time"
      region  = "$.region"
      event   = "$.detail.eventName"
      service = "$.detail.eventSource"
      actor   = "$.detail.userIdentity.arn"
      agent   = "$.detail.userAgent"
      error   = "$.detail.errorCode"
      stack   = "$.detail.resourceId"
      rule    = "$.detail.configRuleName"
    }
    input_template = each.value.name == "${local.name}-stack-drift" ? "\"<time> <region>: CloudFormation stack <stack> has drifted (<rule>). Check it with DetectStackDrift and DescribeStackResourceDrifts (aws-audit README).\"" : "\"<time> <region>: <event> on <service> by <actor>, user agent <agent>, error <error>. Not made by Terraform or CloudFormation. Find it with CloudTrail lookup-events (aws-audit README).\""
  }
}

data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "forward" {
  name               = "${local.name}-forward"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

resource "aws_iam_role_policy" "forward" {
  name = "put-events-home-bus"
  role = aws_iam_role.forward.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "events:PutEvents", Resource = local.home_bus_arn }]
  })
}

resource "aws_cloudwatch_event_target" "to_home_bus" {
  for_each = { for key, rule in local.regional_alert_rules : key => rule if contains(local.forwarding_regions, rule.region) }
  region   = each.value.region
  rule     = aws_cloudwatch_event_rule.alert[each.key].name
  arn      = local.home_bus_arn
  role_arn = aws_iam_role.forward.arn
}

# A parameter that exists only to prove the alert path: tag it by hand, expect an email and a
# drift line in `terraform plan`, then `terraform apply` puts it back.
resource "aws_ssm_parameter" "alert_canary" {
  region = "eu-north-1"
  name   = "/honua/audit/alert-canary"
  type   = "String"
  value  = "Tag me by hand to test the aws-audit change alert; terraform apply reverts it."
  tags   = { Purpose = "aws-audit-alert-canary" }
}

resource "aws_budgets_budget" "audit" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_filter {
    name   = "Service"
    values = ["AWS Config", "AWS CloudTrail"]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
