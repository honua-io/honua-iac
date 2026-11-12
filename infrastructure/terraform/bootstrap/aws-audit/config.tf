locals {
  regional_resource_types = [
    "AWS::EC2::Instance",
    "AWS::EC2::SecurityGroup",
    "AWS::EC2::VPC",
    "AWS::EC2::Subnet",
    "AWS::EC2::EIP",
    "AWS::EC2::LaunchTemplate",
    "AWS::AutoScaling::AutoScalingGroup",
    "AWS::S3::Bucket",
    "AWS::WAFv2::WebACL",
    "AWS::ECS::Cluster",
    "AWS::ECS::Service",
    "AWS::ECS::TaskDefinition",
    "AWS::RDS::DBInstance",
    "AWS::Lambda::Function",
    "AWS::SQS::Queue",
  ]
  # Recorded once, in home_region.
  global_resource_types = [
    "AWS::IAM::Role",
    "AWS::IAM::Policy",
    "AWS::IAM::User",
    "AWS::CloudFront::Distribution",
  ]
  stack_resource_type = "AWS::CloudFormation::Stack"

  recorded_types = {
    for region in var.recorded_regions : region => sort(concat(
      local.regional_resource_types,
      region == var.home_region ? local.global_resource_types : [],
      contains(var.stack_drift_regions, region) ? [local.stack_resource_type] : [],
    ))
  }
}

resource "aws_iam_service_linked_role" "config" {
  aws_service_name = "config.amazonaws.com"
}

resource "aws_config_configuration_recorder" "audit" {
  for_each = var.recorded_regions
  region   = each.key
  name     = local.name
  role_arn = aws_iam_service_linked_role.config.arn

  recording_group {
    all_supported                 = false
    include_global_resource_types = false
    resource_types                = local.recorded_types[each.key]
    recording_strategy {
      use_only = "INCLUSION_BY_RESOURCE_TYPES"
    }
  }

  # At most one configuration item per changed resource per day.
  recording_mode {
    recording_frequency = "DAILY"
  }
}

resource "aws_config_delivery_channel" "audit" {
  for_each       = var.recorded_regions
  region         = each.key
  name           = local.name
  s3_bucket_name = aws_s3_bucket.audit.id
  s3_key_prefix  = local.config_prefix

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.audit, aws_s3_bucket_policy.audit]
}

resource "aws_config_configuration_recorder_status" "audit" {
  for_each   = var.recorded_regions
  region     = each.key
  name       = aws_config_configuration_recorder.audit[each.key].name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.audit]
}

data "aws_iam_policy_document" "config_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# DetectStackDrift reads every resource in a stack with the caller's permissions, so the role gets
# control-plane reads for the resource types our stacks use and nothing that returns data.
data "aws_iam_policy_document" "stack_drift" {
  statement {
    sid = "DetectStackDrift"
    actions = [
      "cloudformation:DetectStackDrift",
      "cloudformation:DetectStackResourceDrift",
      "cloudformation:DescribeStackDriftDetectionStatus",
      "cloudformation:DescribeStackResourceDrifts",
      "cloudformation:DescribeStacks",
      "cloudformation:DescribeStackResource",
      "cloudformation:DescribeStackResources",
      "cloudformation:ListStackResources",
      "cloudformation:GetTemplate",
    ]
    resources = ["arn:${local.partition}:cloudformation:*:${local.account_id}:stack/*/*"]
  }

  statement {
    sid = "ReadStackResources"
    actions = [
      "acm:DescribeCertificate",
      "application-autoscaling:Describe*",
      "autoscaling:Describe*",
      "cloudfront:Get*",
      "cloudfront:List*",
      "ec2:Describe*",
      "ecr:DescribeRepositories",
      "ecr:GetLifecyclePolicy",
      "ecr:GetRepositoryPolicy",
      "ecr:ListTagsForResource",
      "ecs:Describe*",
      "ecs:List*",
      "elasticloadbalancing:Describe*",
      "events:Describe*",
      "events:List*",
      "iam:Get*",
      "iam:List*",
      "kms:DescribeKey",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:ListResourceTags",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:GetPolicy",
      "lambda:GetAlias",
      "lambda:List*",
      "logs:Describe*",
      "logs:ListTagsForResource",
      "rds:Describe*",
      "rds:ListTagsForResource",
      "route53:Get*",
      "route53:List*",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucket*",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:ListAllMyBuckets",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
      "sns:GetTopicAttributes",
      "sns:ListTagsForResource",
      "sqs:GetQueueAttributes",
      "sqs:ListQueueTags",
      "wafv2:Get*",
      "wafv2:List*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "stack_drift" {
  name               = "${local.name}-stack-drift"
  assume_role_policy = data.aws_iam_policy_document.config_assume.json
}

resource "aws_iam_role_policy" "stack_drift" {
  name   = "detect-stack-drift"
  role   = aws_iam_role.stack_drift.id
  policy = data.aws_iam_policy_document.stack_drift.json
}

resource "aws_config_config_rule" "stack_drift" {
  for_each = var.stack_drift_regions
  region   = each.key
  name     = "cloudformation-stack-drift-detection-check"

  source {
    owner             = "AWS"
    source_identifier = "CLOUDFORMATION_STACK_DRIFT_DETECTION_CHECK"
  }
  input_parameters            = jsonencode({ cloudformationRoleArn = aws_iam_role.stack_drift.arn })
  maximum_execution_frequency = "TwentyFour_Hours"
  scope {
    compliance_resource_types = [local.stack_resource_type]
  }

  depends_on = [aws_config_configuration_recorder_status.audit, aws_iam_role_policy.stack_drift]
}
