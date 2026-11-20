data "archive_file" "reaper" {
  type        = "zip"
  source_file = "${path.module}/reaper/handler.py"
  output_path = "${path.module}/.terraform/gate-reaper.zip"
}
resource "aws_iam_role" "reaper" {
  name = "HonuaGateReaper"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}
resource "aws_cloudwatch_log_group" "reaper" {
  name              = "/aws/lambda/honua-gate-reaper"
  retention_in_days = 14
}
resource "aws_iam_role_policy" "reaper" {
  name = "expired-gate-stacks-only"
  role = aws_iam_role.reaper.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([{ Effect = "Allow", Action = "cloudformation:ListStacks", Resource = "*" }, {
      Effect = "Allow", Action = ["cloudformation:DescribeStacks", "cloudformation:ListStackResources"], Resource = local.stack_arn
      }, {
      Effect    = "Allow", Action = "cloudformation:DeleteStack", Resource = local.stack_arn
      Condition = { StringEquals = { "cloudformation:RoleArn" = local.service_role_arn } }
      }, {
      Effect    = "Allow", Action = "iam:PassRole", Resource = local.service_role_arn
      Condition = { StringEquals = { "iam:PassedToService" = "cloudformation.amazonaws.com" } }
      }, {
      Effect = "Allow", Action = "iam:ListRoles", Resource = "*"
      }, {
      Effect = "Allow"
      Action = ["iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:DeleteRolePolicy", "iam:DetachRolePolicy", "iam:DeleteRole"]
      Resource = "arn:aws:iam::${var.member_account_id}:role/honua-gate-*"
      }, {
      Effect   = "Allow", Action = ["kms:DescribeKey", "kms:ListResourceTags"]
      Resource = "arn:aws:kms:us-east-1:${var.member_account_id}:key/*"
      }, {
      Effect   = "Allow", Action = "kms:ScheduleKeyDeletion"
      Resource = "arn:aws:kms:us-east-1:${var.member_account_id}:key/*"
      Condition = {
        StringEquals  = { "aws:ResourceTag/HonuaGate" = "true" }
        NumericEquals = { "kms:ScheduleKeyDeletionPendingWindowInDays" = 7 }
      }
      }, {
      Effect = "Allow", Action = "cloudtrail:DescribeTrails", Resource = "*"
      }, {
      Effect   = "Allow", Action = ["cloudtrail:GetTrail", "cloudtrail:DeleteTrail"]
      Resource = "arn:aws:cloudtrail:us-east-1:${var.member_account_id}:trail/honua-protection-*"
      }, {
      Effect = "Deny", Action = ["cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail", "cloudtrail:StopLogging", "cloudtrail:PutEventSelectors"]
      Resource = [
        "arn:aws:cloudtrail:us-east-1:${var.member_account_id}:trail/honua-audit",
        "arn:aws:cloudtrail:us-east-1:${var.member_account_id}:trail/honua-audit*"
      ]
      }, {
      Effect = "Allow", Action = "s3:ListAllMyBuckets", Resource = "*"
      }, {
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:ListBucketVersions", "s3:ListBucketMultipartUploads", "s3:DeleteBucket"]
      Resource = "arn:aws:s3:::honua-gate-*"
      }, {
      Effect   = "Allow"
      Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload"]
      Resource = "arn:aws:s3:::honua-gate-*/*"
      }, {
      Effect = "Deny", Action = ["s3:DeleteBucket", "s3:DeleteObject", "s3:DeleteObjectVersion"]
      Resource = [
        "arn:aws:s3:::honua-audit", "arn:aws:s3:::honua-audit/*",
        "arn:aws:s3:::honua-audit-*", "arn:aws:s3:::honua-audit-*/*"
      ]
      }, {
      Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.reaper.arn}:*"
      }, {
      Effect = "Allow", Action = "acm:ListCertificates", Resource = "*"
      }, {
      Effect   = "Allow", Action = ["acm:DescribeCertificate", "acm:ListTagsForCertificate"]
      Resource = local.reaper_certificates
      }, {
      # Unused gate certificates: CloudFormation tags them with the stack's HonuaGate=true.
      Effect    = "Allow", Action = "acm:DeleteCertificate", Resource = local.reaper_certificates
      Condition = { StringEquals = { "aws:ResourceTag/HonuaGate" = "true" } }
      }], nonsensitive(length(var.temporary_orphan_certificate_ids)) == 0 ? [] : [{
      # Untagged certificates left by denied rollbacks (20 Nov); exact reviewed IDs only.
      Effect   = "Allow", Action = "acm:DeleteCertificate"
      Resource = [for id in sort(tolist(var.temporary_orphan_certificate_ids)) : "arn:aws:acm:us-east-1:${var.member_account_id}:certificate/${id}"]
    }])
  })
}
locals {
  reaper_certificates = "arn:aws:acm:us-east-1:${var.member_account_id}:certificate/*"
}
resource "aws_lambda_function" "reaper" {
  function_name                  = "honua-gate-reaper"
  role                           = aws_iam_role.reaper.arn
  runtime                        = "python3.13"
  handler                        = "handler.lambda_handler"
  filename                       = data.archive_file.reaper.output_path
  source_code_hash               = data.archive_file.reaper.output_base64sha256
  timeout                        = 300
  memory_size                    = 128
  reserved_concurrent_executions = 1
  environment {
    variables = {
      SERVICE_ROLE_ARN      = local.service_role_arn
      ORPHAN_DRY_RUN        = tostring(var.orphan_cleanup_dry_run)
      TRAIL_CLEANUP_DRY_RUN = tostring(var.protection_trail_cleanup_dry_run)
      # Certificate cleanup reads nothing without a gate test domain.
      GATE_TEST_DOMAIN                 = var.gate_test_domain
      TEMPORARY_ORPHAN_CERTIFICATE_IDS = join(",", sort(tolist(var.temporary_orphan_certificate_ids)))
    }
  }
  depends_on = [aws_iam_role_policy.reaper]
}
resource "aws_cloudwatch_event_rule" "nightly" {
  name                = "honua-gate-nightly-reaper"
  schedule_expression = "cron(0 3 * * ? *)"
  state               = "ENABLED"
}
resource "aws_cloudwatch_event_target" "reaper" {
  rule = aws_cloudwatch_event_rule.nightly.name
  arn  = aws_lambda_function.reaper.arn
}
resource "aws_lambda_permission" "nightly" {
  statement_id   = "NightlyGateCleanup"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.reaper.function_name
  principal      = "events.amazonaws.com"
  source_arn     = aws_cloudwatch_event_rule.nightly.arn
  source_account = var.member_account_id
}
