mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:123456789012:honua-audit-alerts" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:us-east-1:123456789012:rule/mock" }
  }
}

variables {
  alert_email = "alerts@example.com"
}

run "trail_records_every_management_event_with_validation" {
  command = plan
  assert {
    condition = (aws_cloudtrail.audit.is_multi_region_trail && aws_cloudtrail.audit.enable_log_file_validation
    && aws_cloudtrail.audit.event_selector[0].read_write_type == "All")
    error_message = "One multi-Region trail, read and write management events, log file validation on."
  }
}

run "alerts_reach_one_topic" {
  command = plan
  assert {
    condition     = length(aws_cloudwatch_event_target.to_topic) == 4 && alltrue([for t in aws_cloudwatch_event_target.to_home_bus : t.region != "us-east-1"])
    error_message = "Home-Region rules publish to the topic; the other Regions forward to the home bus."
  }
  assert {
    condition = alltrue([for key, rule in aws_cloudwatch_event_rule.alert :
    strcontains(rule.event_pattern, "*Terraform/*") && length(rule.event_pattern) <= 2048 if strcontains(key, "-change-")])
    error_message = "Every change rule ignores calls made by Terraform and fits EventBridge's 2048-character pattern limit."
  }
}
