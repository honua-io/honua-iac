mock_provider "aws" {}

override_module {
  target = module.eks
  outputs = {
    cluster_name                   = "honua-eks"
    environment                    = "it"
    cluster_arn                    = "arn:aws:eks:us-east-1:123456789012:cluster/honua-eks"
    cluster_endpoint               = "https://eks.example.test"
    vpc_id                         = "vpc-1234567890"
    control_plane_target_kind      = "aws-eks-cluster"
    control_plane_backend_name     = "aws-eks"
    control_plane_telemetry_policy = "prometheus"
    honua_metrics_target           = "honua.monitoring.svc.cluster.local:8080"
    oidc_provider                  = "https://oidc.eks.example.test"
    oidc_provider_arn              = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.example.test"
    cluster_security_group_id      = "sg-cluster"
    node_security_group_id         = "sg-node"
  }
}

run "eks_outputs_are_split_by_audience" {
  command = plan

  assert {
    condition     = output.infrastructure_outputs.cluster.name == "honua-eks"
    error_message = "aws-eks should expose cluster details through infrastructure_outputs."
  }

  assert {
    condition     = output.honua_integration_outputs.control_plane.backend_name == "aws-eks"
    error_message = "aws-eks should isolate Honua metadata in honua_integration_outputs."
  }
}
