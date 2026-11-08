mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_instance" {
    defaults = { arn = "arn:aws:ec2:us-east-1:123456789012:instance/i-0123456789abcdef0", id = "i-0123456789abcdef0", iam_instance_profile = "" }
  }
}

variables {
  allowed_ssh_cidrs  = ["192.0.2.1/32"]
  ssh_public_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest"
  budget_alert_email = "ops@example.com"
}

override_data {
  target = data.aws_iam_policy_document.scheduler_assume
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}
override_data {
  target = data.aws_iam_policy_document.scheduler_stop
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

run "spot_host_that_stops_itself" {
  command = apply
  assert {
    condition     = one(aws_instance.build.instance_market_options).market_type == "spot" && one(one(aws_instance.build.instance_market_options).spot_options).instance_interruption_behavior == "stop" && one(one(aws_instance.build.instance_market_options).spot_options).spot_instance_type == "persistent"
    error_message = "The build host must be a persistent spot instance that stops on interruption."
  }
  assert {
    condition     = one(aws_instance.build.metadata_options).http_tokens == "required" && (aws_instance.build.iam_instance_profile == null || aws_instance.build.iam_instance_profile == "")
    error_message = "The build host must require IMDSv2 and carry no instance profile."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.idle_stop.evaluation_periods == 6 && contains(aws_cloudwatch_metric_alarm.idle_stop.alarm_actions, "arn:aws:automate:us-east-1:ec2:stop")
    error_message = "An idle alarm must stop the host after 30 minutes."
  }
  assert {
    condition     = aws_scheduler_schedule.nightly_stop.schedule_expression == "cron(0 3 * * ? *)" && aws_scheduler_schedule.nightly_stop.schedule_expression_timezone == "America/Los_Angeles" && one(aws_scheduler_schedule.nightly_stop.target).arn == "arn:aws:scheduler:::aws-sdk:ec2:stopInstances" && contains(jsondecode(one(aws_scheduler_schedule.nightly_stop.target).input).InstanceIds, aws_instance.build.id)
    error_message = "A nightly schedule at 03:00 Pacific must call StopInstances for the build host."
  }
  assert {
    condition     = one(aws_budgets_budget.build_host.cost_filter).name == "Service" && contains(one(aws_budgets_budget.build_host.cost_filter).values, "Amazon Elastic Compute Cloud - Compute") && length(aws_budgets_budget.build_host.notification) == 2
    error_message = "EC2 compute cost must raise budget email alerts."
  }
  assert {
    condition     = length(aws_security_group.build.ingress) == 1 && one(aws_security_group.build.ingress).cidr_blocks == tolist(["192.0.2.1/32"]) && one(aws_security_group.build.ingress).from_port == 22
    error_message = "Only configured SSH ingress is allowed."
  }
  assert {
    condition     = startswith(aws_instance.build.user_data, "#!/bin/bash") && strcontains(aws_instance.build.user_data, "apt_retry install -y git")
    error_message = "User data must be the shared Docker installer followed by the build tools."
  }
}

run "reject_world_ssh" {
  command = plan
  variables { allowed_ssh_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.allowed_ssh_cidrs]
}
