mock_provider "aws" {}

override_data {
  target = data.aws_availability_zones.available

  values = {
    names = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}

override_data {
  target = module.eks.data.aws_caller_identity.current

  values = {
    account_id = "123456789012"
    arn        = "arn:aws:sts::123456789012:assumed-role/honua-terraform-test/session"
    user_id    = "AROA123456789012EXAMPLE:session"
  }
}

override_data {
  target = module.eks.data.aws_partition.current

  values = {
    partition          = "aws"
    dns_suffix         = "amazonaws.com"
    reverse_dns_prefix = "com.amazonaws"
  }
}

override_data {
  target = module.eks.data.aws_iam_policy_document.assume_role_policy

  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

override_data {
  target = module.eks.data.aws_iam_policy_document.custom

  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

override_data {
  target = module.eks.module.eks_managed_node_group["default"].data.aws_iam_policy_document.assume_role_policy

  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

override_data {
  target = module.eks.module.eks_managed_node_group["default"].data.aws_partition.current

  values = {
    partition          = "aws"
    dns_suffix         = "amazonaws.com"
    reverse_dns_prefix = "com.amazonaws"
  }
}

run "managed_node_group_bounds" {
  command = plan

  variables {
    node_min_size     = 2
    node_desired_size = 1
    node_max_size     = 3
  }

  expect_failures = [
    check.managed_node_group_bounds,
  ]
}

run "control_plane_outputs_shape" {
  command = plan

  assert {
    condition     = output.control_plane_target_kind == "Kubernetes"
    error_message = "Expected target kind Kubernetes."
  }

  assert {
    condition     = output.control_plane_backend_name == "honua-gitops-kubernetes"
    error_message = "Expected backend name honua-gitops-kubernetes."
  }

  assert {
    condition     = output.honua_metrics_target == "honua"
    error_message = "Expected the default Honua metrics target hint."
  }
}
