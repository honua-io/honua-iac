mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-north-1a", "eu-north-1b", "eu-north-1c"] }
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
  target = data.aws_iam_policy_document.stop_group
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

run "spot_host_that_stops_itself" {
  command = apply
  assert {
    condition     = aws_autoscaling_group.build.min_size == 0 && aws_autoscaling_group.build.max_size == 1 && aws_autoscaling_group.build.desired_capacity == 1
    error_message = "The group must support zero or one build host."
  }
  assert {
    condition     = one(one(aws_autoscaling_group.build.mixed_instances_policy).instances_distribution).on_demand_base_capacity == 0 && one(one(aws_autoscaling_group.build.mixed_instances_policy).instances_distribution).on_demand_percentage_above_base_capacity == 0 && one(one(aws_autoscaling_group.build.mixed_instances_policy).instances_distribution).spot_allocation_strategy == "price-capacity-optimized"
    error_message = "Only price-capacity-optimized Spot capacity is allowed."
  }
  assert {
    condition     = toset([for item in one(one(aws_autoscaling_group.build.mixed_instances_policy).launch_template).override : item.instance_type]) == toset(["c6i.4xlarge", "c7i.4xlarge", "m6i.4xlarge", "m7i.4xlarge", "c6a.4xlarge", "m6a.4xlarge", "c5.4xlarge"])
    error_message = "All seven equivalent 16-vCPU types must be offered."
  }
  assert {
    condition     = length(aws_subnet.build) == 3 && toset([for subnet in aws_subnet.build : subnet.availability_zone]) == toset(data.aws_availability_zones.build.names) && toset(aws_autoscaling_group.build.vpc_zone_identifier) == toset([for subnet in aws_subnet.build : subnet.id])
    error_message = "Every regional availability zone must be available to the group."
  }
  assert {
    condition     = one(aws_launch_template.build.metadata_options).http_tokens == "required" && one(aws_launch_template.build.iam_instance_profile).name == aws_iam_instance_profile.build.name && one(one(aws_launch_template.build.block_device_mappings).ebs).encrypted
    error_message = "The template must require IMDSv2, encrypted storage and the scoped idle-stop role."
  }
  assert {
    condition     = aws_scheduler_schedule.nightly_stop.state == "DISABLED" && one(aws_scheduler_schedule.nightly_stop.target).arn == "arn:aws:scheduler:::aws-sdk:autoscaling:setDesiredCapacity" && jsondecode(one(aws_scheduler_schedule.nightly_stop.target).input).DesiredCapacity == 0 && jsondecode(one(aws_scheduler_schedule.nightly_stop.target).input).AutoScalingGroupName == aws_autoscaling_group.build.name
    error_message = "The disabled-by-default nightly stop must scale the group to zero."
  }
  assert {
    condition     = one(data.aws_iam_policy_document.stop_group.statement).actions == toset(["autoscaling:SetDesiredCapacity"]) && one(data.aws_iam_policy_document.stop_group.statement).resources == toset([aws_autoscaling_group.build.arn]) && aws_iam_role_policy.build.policy == data.aws_iam_policy_document.stop_group.json
    error_message = "The host may only change desired capacity on its own group."
  }
  assert {
    condition     = alltrue([for tag in aws_autoscaling_group.build.tag : tag.propagate_at_launch]) && contains([for tag in aws_autoscaling_group.build.tag : "${tag.key}=${tag.value}"], "Name=honua-lane-build-host")
    error_message = "Stable discovery tags must propagate to replacement instances."
  }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.build.user_data), "python3-boto3") && strcontains(base64decode(aws_launch_template.build.user_data), "fonts-dejavu-core libatomic1 xmlstarlet skopeo clang zlib1g-dev")
    error_message = "Replacement hosts need the idle-stop SDK and native build/runtime dependencies."
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
    condition     = strcontains(base64decode(aws_launch_template.build.user_data), "OnUnitActiveSec=5min") && strcontains(base64decode(aws_launch_template.build.user_data), "systemctl enable --now honua-build-host-idle-stop.timer") && strcontains(base64decode(aws_launch_template.build.user_data), "ExecStart=/usr/local/sbin/honua-build-host-idle-stop")
    error_message = "User data must install and enable the five-minute idle-stop timer."
  }
  assert {
    condition     = startswith(base64decode(aws_launch_template.build.user_data), "#!/bin/bash") && strcontains(base64decode(aws_launch_template.build.user_data), "apt_retry install -y git")
    error_message = "User data must be the shared Docker installer followed by the build tools."
  }
}

run "nightly_stop_when_enabled" {
  command = apply
  variables { nightly_stop_enabled = true }
  assert {
    condition     = aws_scheduler_schedule.nightly_stop.state == "ENABLED" && one(aws_scheduler_schedule.nightly_stop.target).arn == "arn:aws:scheduler:::aws-sdk:autoscaling:setDesiredCapacity" && jsondecode(one(aws_scheduler_schedule.nightly_stop.target).input).DesiredCapacity == 0
    error_message = "Enabling the nightly stop must scale the group to zero."
  }
}

run "reject_world_ssh" {
  command = plan
  variables { allowed_ssh_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.allowed_ssh_cidrs]
}

run "configured_idle_window" {
  command = apply
  variables { idle_stop_minutes = 10 }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.build.user_data), base64encode(jsonencode({ region = var.region, group = "honua-lane-build-host", idle_seconds = 600 })))
    error_message = "The activity timer must receive the configured idle window and fleet identity."
  }
}
