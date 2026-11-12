mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_security_group" {
    defaults = { id = "sg-0123456789abcdef0" }
  }
}

variables {
  allowed_ssh_cidrs  = ["192.0.2.1/32"]
  ssh_public_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest"
  budget_alert_email = "ops@example.com"
}

override_data {
  target = data.aws_iam_policy_document.ec2_assume
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}
override_data {
  target = data.aws_iam_policy_document.lanes
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

# Plan only: the data volume's prevent_destroy forbids the test teardown an apply would need.
run "on_demand_host_with_persistent_lane_volume" {
  command = plan
  assert {
    condition     = aws_instance.lanes.instance_initiated_shutdown_behavior == "stop" && local.host_config.idle_seconds == 1800
    error_message = "Idle shutdown must stop, never terminate, with a 30-minute default."
  }
  assert {
    condition     = local.host_config.activity_config == "/home/ubuntu/lanes/idle-stop.json"
    error_message = "Pending-work guards must survive replacement on the data volume."
  }
  assert {
    condition     = length(aws_instance.lanes.instance_market_options) == 0
    error_message = "Lanes run for hours; the host must be on-demand, never Spot."
  }
  assert {
    condition     = aws_instance.lanes.metadata_options[0].http_tokens == "required"
    error_message = "The instance must require IMDSv2."
  }
  assert {
    condition     = aws_ebs_volume.lanes.size == 500 && aws_ebs_volume.lanes.availability_zone == aws_subnet.lanes.availability_zone && aws_ebs_volume.lanes.encrypted
    error_message = "The encrypted data volume must share the instance's zone."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.build_host_from_lanes[0].security_group_id == "sg-0123456789abcdef0" && aws_vpc_security_group_ingress_rule.build_host_from_lanes[0].from_port == 22
    error_message = "The build host security group must admit SSH from the lane host."
  }
  assert {
    condition     = one(aws_budgets_budget.lane_host.cost_filter).values == tolist(["EUN1-BoxUsage:m6i.4xlarge"])
    error_message = "The budget must track only the lane host's on-demand compute."
  }
}

run "build_host_rule_is_optional" {
  command = plan
  variables {
    build_host_ssh_access = false
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.build_host_from_lanes) == 0
    error_message = "Disabling build host access must add no rule to its security group."
  }
}

run "ci_events_queue_access_only_when_configured" {
  command = plan
  assert {
    condition     = length(aws_iam_role_policy.ci_events) == 0
    error_message = "No queue access unless ci_events_queue_arn is set."
  }
}

run "ci_events_queue_access_is_receive_delete_on_one_queue" {
  command = plan
  variables {
    ci_events_queue_arn = "arn:aws:sqs:eu-north-1:123456789012:honua-ci-events"
  }
  override_data {
    target = data.aws_iam_policy_document.ci_events[0]
    values = { json = "{\"Statement\":[{\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"arn:aws:sqs:eu-north-1:123456789012:honua-ci-events\"}]}" }
  }
  assert {
    condition     = length(aws_iam_role_policy.ci_events) == 1 && aws_iam_role_policy.ci_events[0].name == "ci-events-consume"
    error_message = "The lane host role gets the ci-events consume policy."
  }
}

run "reject_too_short_idle_window" {
  command = plan
  variables { idle_stop_minutes = 1 }
  expect_failures = [var.idle_stop_minutes]
}
