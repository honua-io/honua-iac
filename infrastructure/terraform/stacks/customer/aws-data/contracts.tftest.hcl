mock_provider "aws" {}

override_module {
  target = module.data
  outputs = {
    vpc_id                  = "vpc-1234567890"
    vpc_cidr                = "10.40.0.0/16"
    public_subnet_ids       = ["subnet-public-a", "subnet-public-b"]
    private_subnet_ids      = ["subnet-private-a", "subnet-private-b"]
    db_endpoint             = "honua-db.internal"
    db_connection_string    = "Host=honua-db.internal;Database=honua"
    redis_connection_string = "rediss://cache.example.test:6379"
  }
}

run "aws_data_groups_operator_outputs" {
  command = plan

  assert {
    condition     = output.infrastructure_outputs.network.vpc_id == "vpc-1234567890"
    error_message = "aws-data should expose network outputs through infrastructure_outputs."
  }

  assert {
    condition     = output.vpc_cidr == "10.40.0.0/16"
    error_message = "aws-data should preserve legacy outputs while adding grouped outputs."
  }
}
