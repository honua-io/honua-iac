mock_provider "aws" {
  override_during = plan
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      id     = "us-east-1"
      name   = "us-east-1"
      region = "us-east-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_elb_service_account" {
    defaults = {
      arn = "arn:aws:iam::127311923021:root"
      id  = "127311923021"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      dns_suffix         = "amazonaws.com"
      id                 = "aws"
      partition          = "aws"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/honua-test/0000000000000000"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/honua-test/0000000000000000"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/honua-test/0000000000000000/1111111111111111"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/honua-test"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/honua-test"
    }
  }
}

mock_provider "random" {}
mock_provider "null" {}

variables {
  # Recommended in Production; unset only plans with a check warning.
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"

  image                            = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password                   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  connection_encryption_master_key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  existing_vpc_id             = "vpc-0123456789abcdef0"
  existing_vpc_cidr           = "10.0.0.0/16"
  existing_public_subnet_ids  = ["subnet-00000000000000001", "subnet-00000000000000002"]
  existing_private_subnet_ids = ["subnet-00000000000000003", "subnet-00000000000000004"]

  existing_db_endpoint          = "postgres.example.internal"
  existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"

  redis_enabled           = false
  kms_key_arn             = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
  alb_access_logs_enabled = false
}

run "disabled_by_default" {
  command = plan
  assert {
    condition     = length(aws_batch_job_queue.gp) == 0 && length(aws_batch_compute_environment.gp) == 0 && length(aws_batch_job_definition.gp) == 0 && length(aws_iam_role_policy.gp_batch_submit) == 0
    error_message = "Batch must be absent by default."
  }
}

run "private_fargate_workers" {
  command = plan
  variables {
    gp_batch = {
      image                      = "ghcr.io/honua-io/honua-worker-gdal@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      database_security_group_id = "sg-0123456789abcdef0"
      max_vcpus                  = 4
    }
    file_storage_provider           = "AwsS3"
    file_storage_aws_s3_bucket_name = "test-files"
    file_storage_aws_s3_key_prefix  = "honua/gp"
    permissions_boundary_arn        = "arn:aws:iam::123456789012:policy/test-boundary"
  }
  override_resource {
    override_during = plan
    target          = aws_secretsmanager_secret.db_connection
    values          = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-db-AbC123" }
  }
  override_resource {
    override_during = plan
    target          = aws_batch_job_queue.gp[0]
    values          = { arn = "arn:aws:batch:us-east-1:123456789012:job-queue/test-gp" }
  }
  override_resource {
    override_during = plan
    target          = aws_batch_job_definition.gp[0]
    values          = { arn = "arn:aws:batch:us-east-1:123456789012:job-definition/test-gp:1" }
  }
  assert {
    condition     = aws_batch_compute_environment.gp[0].compute_resources[0].type == "FARGATE" && toset(aws_batch_compute_environment.gp[0].compute_resources[0].subnets) == toset(var.existing_private_subnet_ids)
    error_message = "Workers must use Fargate in service private subnets."
  }
  assert {
    condition     = aws_security_group_rule.gp_batch_external_database[0].security_group_id == var.gp_batch.database_security_group_id && aws_security_group_rule.gp_batch_external_database[0].from_port == 5432
    error_message = "External PostgreSQL must admit the worker security group."
  }
  assert {
    condition     = aws_iam_role.gp_batch_execution[0].permissions_boundary == var.permissions_boundary_arn && aws_iam_role.gp_batch_job[0].permissions_boundary == var.permissions_boundary_arn
    error_message = "Both worker roles require the operator boundary."
  }
  assert {
    condition     = local.gp_batch_environment.ControlPlane__TriggerMode == "Poll" && local.gp_batch_environment.ControlPlane__ExecutionWorkloads__0__Backend == "honua-aws-batch" && local.gp_batch_environment.ControlPlane__ExecutionWorkloads__0__ParameterEntries__1__Key == "batch.job_definition_arn"
    error_message = "ECS must select the Batch workload and its own polling reconciler."
  }
  assert {
    condition     = toset(flatten([for s in jsondecode(aws_iam_role_policy.gp_batch_submit[0].policy).Statement : s.Action])) == toset(["batch:SubmitJob", "batch:DescribeJobs", "batch:ListJobs", "batch:CancelJob", "batch:TerminateJob"])
    error_message = "The server Batch policy must contain only the five authorized actions."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.gp_batch_job[0].policy).Statement[3].Condition.StringLike["s3:prefix"] == ["honua/gp", "honua/gp/*"] && jsondecode(aws_iam_role_policy.gp_batch_job[0].policy).Statement[4].Resource[0] == "arn:aws:s3:::test-files/honua/gp/*"
    error_message = "Worker list/object access must stay within the configured file prefix."
  }
  assert {
    condition     = local.db_pool_inputs.other_connections == 8
    error_message = "Database budgeting must reserve the two-connection worker pool per concurrent vCPU."
  }
}

run "requires_shared_files" {
  command = plan
  variables {
    gp_batch = { image = "worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", database_security_group_id = "sg-0123456789abcdef0" }
  }
  expect_failures = [terraform_data.gp_batch_validation]
}

run "rejects_unpinned_worker" {
  command = plan
  variables {
    gp_batch                        = { image = "worker:latest", database_security_group_id = "sg-0123456789abcdef0" }
    file_storage_provider           = "AwsS3"
    file_storage_aws_s3_bucket_name = "test-files"
    file_storage_aws_s3_key_prefix  = "honua/gp"
  }
  expect_failures = [var.gp_batch]
}
