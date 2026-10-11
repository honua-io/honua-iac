# RDS Proxy (honua-release e2e-cloud-aws run 38133126673, aws-serverless): with
# >= 6 API Lambda environments x (8 pool + 1 preflight pool, held while frozen),
# the control-plane functions, GP Batch jobs and bootstrap, a db.t3.micro
# (~82 usable connections) ran out of slots ("53300") and the API host crashed
# in the PostGIS preflight. enable_rds_proxy puts RDS Proxy in front of the
# module-managed instance and routes every server process through it.
#
# Off (the default) creates nothing and leaves every consumer on the direct
# connection_string secret. On creates the proxy, its default target group, the
# instance target and the security-group rules; the API Lambda, the
# control-plane event Lambdas and the GP Batch job definitions then read the
# proxy_connection_string secret, whose Host is the proxy endpoint, while the
# connection_string secret (migrations, seeding) keeps the instance endpoint.

mock_provider "aws" {
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

  mock_data "aws_partition" {
    defaults = {
      dns_suffix         = "amazonaws.com"
      id                 = "aws"
      partition          = "aws"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:us-east-1:123456789012:repository/honua-server"
      registry_id    = "123456789012"
      repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
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

  mock_resource "aws_batch_compute_environment" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:123456789012:compute-environment/honua-mock"
    }
  }

  mock_resource "aws_batch_job_queue" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:123456789012:job-queue/honua-mock"
    }
  }

  mock_resource "aws_batch_job_definition" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:123456789012:job-definition/honua-mock:1"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:honua-mock:*"
    }
  }

  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      arn           = "arn:aws:apigateway:us-east-1::/apis/abcdefghij"
      execution_arn = "arn:aws:execute-api:us-east-1:123456789012:abcdefghij"
    }
  }

  # Control-plane event targets and schedules validate these ARNs in-provider.
  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:123456789012:function:honua-mock"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-1:123456789012:rule/honua-mock"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-mock-AbCdEf"
    }
  }

  mock_resource "aws_db_proxy" {
    defaults = {
      arn      = "arn:aws:rds:us-east-1:123456789012:db-proxy:prx-0123456789abcdef0"
      endpoint = "honua-mock-pg-proxy.proxy-abcdefghijkl.us-east-1.rds.amazonaws.com"
    }
  }

  # RDS names the default target group "default"; a random mock name can fail
  # the provider's own name validation on aws_db_proxy_target.
  mock_resource "aws_db_proxy_default_target_group" {
    defaults = {
      name = "default"
    }
  }
}

mock_provider "random" {}
mock_provider "null" {}

# Distinct ARNs so the assertions can tell the direct and proxy secrets apart.
override_resource {
  target = aws_secretsmanager_secret.connection_string
  values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-it/connection-string-Dir123" }
}
override_resource {
  target = aws_secretsmanager_secret.proxy_connection_string
  values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-it/db-proxy-connection-Prx123" }
}
override_resource {
  target = aws_secretsmanager_secret.rds_proxy_auth
  values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-it/rds-proxy-auth-Aut123" }
}

variables {
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"

  image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password = "Synthetic-Terraform-Test-Admin-4721!aA1"
  # checkov:skip=CKV_SECRET_6: Synthetic test-only database password for mocked providers, not a credential.
  db_password = "Synthetic-Terraform-Test-Db-Password-1"

  redis_enabled               = false
  enable_control_plane_events = true
  enable_gp_batch             = true
}

run "off_by_default_creates_no_proxy" {
  command = plan

  assert {
    condition = (
      length(aws_db_proxy.this) == 0 &&
      length(aws_db_proxy_default_target_group.this) == 0 &&
      length(aws_db_proxy_target.this) == 0 &&
      length(aws_security_group.rds_proxy) == 0 &&
      length(aws_security_group_rule.rds_proxy_from_clients) == 0 &&
      length(aws_security_group_rule.rds_proxy_to_rds) == 0 &&
      length(aws_security_group_rule.rds_from_rds_proxy) == 0 &&
      length(aws_secretsmanager_secret.rds_proxy_auth) == 0 &&
      length(aws_secretsmanager_secret.proxy_connection_string) == 0 &&
      length(aws_iam_role.rds_proxy) == 0 &&
      length(aws_iam_role_policy.rds_proxy) == 0 &&
      length(terraform_data.rds_proxy_inputs) == 0
    )
    error_message = "enable_rds_proxy defaults to false and must create no proxy resources."
  }

  assert {
    condition     = local.runtime_connection_secret.name == aws_secretsmanager_secret.connection_string.name
    error_message = "With the proxy off, every server process must keep reading the direct connection_string secret."
  }
}

run "off_keeps_the_direct_endpoint_everywhere" {
  command = apply

  assert {
    condition     = startswith(aws_secretsmanager_secret_version.connection_string.secret_string, "Host=${module.rds[0].db_instance_address};")
    error_message = "With the proxy off the connection string must point at the RDS instance."
  }

  assert {
    condition = alltrue([
      for fn in [aws_lambda_function.this, aws_lambda_function.control_plane_tick[0]] :
      fn.environment[0].variables["ConnectionStrings__DefaultConnection"] == "aws:secretsmanager:${aws_secretsmanager_secret.connection_string.arn}"
    ])
    error_message = "With the proxy off the Lambdas must read the connection_string secret."
  }

  assert {
    condition     = output.rds_proxy_endpoint == null && output.rds_proxy_arn == null && output.runtime_db_connection_secret_arn == aws_secretsmanager_secret.connection_string.arn
    error_message = "With the proxy off the proxy outputs are null and the runtime secret is the direct one."
  }
}

run "on_creates_the_proxy_and_routes_every_process_through_it" {
  command = apply

  variables {
    enable_rds_proxy = true
  }

  assert {
    condition = (
      length(aws_db_proxy.this) == 1 &&
      aws_db_proxy.this[0].engine_family == "POSTGRESQL" &&
      aws_db_proxy.this[0].require_tls &&
      one(aws_db_proxy.this[0].auth).auth_scheme == "SECRETS" &&
      one(aws_db_proxy.this[0].auth).secret_arn == aws_secretsmanager_secret.rds_proxy_auth[0].arn &&
      aws_db_proxy.this[0].role_arn == aws_iam_role.rds_proxy[0].arn &&
      aws_db_proxy.this[0].idle_client_timeout == 600 &&
      toset(aws_db_proxy.this[0].vpc_security_group_ids) == toset([aws_security_group.rds_proxy[0].id])
    )
    error_message = "The proxy must be PostgreSQL, TLS-only, authenticate with the credentials secret through its own role, and sit in the proxy security group."
  }

  assert {
    condition     = jsondecode(aws_secretsmanager_secret_version.rds_proxy_auth[0].secret_string) == { username = "honua", password = "Synthetic-Terraform-Test-Db-Password-1" }
    error_message = "The proxy credentials secret must be the {username, password} JSON RDS Proxy requires."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.rds_proxy[0].policy).Statement[0].Resource == [aws_secretsmanager_secret.rds_proxy_auth[0].arn]
    error_message = "The proxy role may read only the proxy credentials secret."
  }

  assert {
    condition = (
      length(aws_db_proxy_default_target_group.this) == 1 &&
      one(aws_db_proxy_default_target_group.this[0].connection_pool_config).max_connections_percent == 90 &&
      one(aws_db_proxy_default_target_group.this[0].connection_pool_config).max_idle_connections_percent == 50 &&
      one(aws_db_proxy_default_target_group.this[0].connection_pool_config).connection_borrow_timeout == 120
    )
    error_message = "The default target group must cap the proxy at 90% of max_connections, keep up to 50% idle and wait 120 s to borrow."
  }

  assert {
    condition = (
      length(aws_db_proxy_target.this) == 1 &&
      aws_db_proxy_target.this[0].db_instance_identifier == module.rds[0].db_instance_identifier &&
      aws_db_proxy_target.this[0].target_group_name == aws_db_proxy_default_target_group.this[0].name
    )
    error_message = "The proxy's default target group must target the module's RDS instance."
  }

  assert {
    condition = (
      toset(keys(aws_security_group_rule.rds_proxy_from_clients)) == toset(["lambda", "gp_batch"]) &&
      aws_security_group_rule.rds_proxy_from_clients["lambda"].source_security_group_id == aws_security_group.lambda.id &&
      aws_security_group_rule.rds_proxy_from_clients["gp_batch"].source_security_group_id == aws_security_group.batch[0].id &&
      alltrue([for rule in aws_security_group_rule.rds_proxy_from_clients : rule.type == "ingress" && rule.from_port == 5432 && rule.to_port == 5432 && rule.security_group_id == aws_security_group.rds_proxy[0].id])
    )
    error_message = "The proxy must admit 5432 from the Lambda and GP Batch security groups."
  }

  assert {
    condition = (
      aws_security_group_rule.rds_proxy_to_rds[0].type == "egress" &&
      aws_security_group_rule.rds_proxy_to_rds[0].security_group_id == aws_security_group.rds_proxy[0].id &&
      aws_security_group_rule.rds_proxy_to_rds[0].source_security_group_id == aws_security_group.rds[0].id &&
      aws_security_group_rule.rds_from_rds_proxy[0].type == "ingress" &&
      aws_security_group_rule.rds_from_rds_proxy[0].security_group_id == aws_security_group.rds[0].id &&
      aws_security_group_rule.rds_from_rds_proxy[0].source_security_group_id == aws_security_group.rds_proxy[0].id &&
      aws_security_group_rule.rds_from_rds_proxy[0].from_port == 5432
    )
    error_message = "The proxy must reach the RDS security group on 5432, and the RDS security group must admit the proxy."
  }

  assert {
    condition = (
      startswith(aws_secretsmanager_secret_version.proxy_connection_string[0].secret_string, "Host=honua-mock-pg-proxy.proxy-abcdefghijkl.us-east-1.rds.amazonaws.com;Port=5432;") &&
      strcontains(aws_secretsmanager_secret_version.proxy_connection_string[0].secret_string, ";SSL Mode=Require;") &&
      strcontains(aws_secretsmanager_secret_version.proxy_connection_string[0].secret_string, ";Maximum Pool Size=8;") &&
      endswith(aws_secretsmanager_secret_version.proxy_connection_string[0].secret_string, ";No Reset On Close=true;Max Auto Prepare=0")
    )
    error_message = "The proxy connection string must use the proxy endpoint, TLS, the pool cap and the pinning-avoidance keywords."
  }

  assert {
    condition     = startswith(aws_secretsmanager_secret_version.connection_string.secret_string, "Host=${module.rds[0].db_instance_address};")
    error_message = "The connection_string secret (migrations, seeding, db_connection_secret_arn) must keep the direct instance endpoint."
  }

  assert {
    condition = alltrue([
      for fn in [aws_lambda_function.this, aws_lambda_function.control_plane_reconcile[0], aws_lambda_function.control_plane_backstop[0], aws_lambda_function.control_plane_tick[0]] :
      fn.environment[0].variables["ConnectionStrings__DefaultConnection"] == "aws:secretsmanager:${aws_secretsmanager_secret.proxy_connection_string[0].name}"
    ])
    error_message = "The API and control-plane event Lambdas must read the proxy connection string (by name, within the 4 KB environment budget)."
  }

  assert {
    condition = alltrue([
      for tier, jd in aws_batch_job_definition.gp :
      one([for e in jsondecode(jd.container_properties).environment : e.value if e.name == "ConnectionStrings__DefaultConnection"]) == "aws:secretsmanager:${aws_secretsmanager_secret.proxy_connection_string[0].arn}"
    ])
    error_message = "Every GP Batch job-definition tier must read the proxy connection string."
  }

  assert {
    condition     = contains(local.lambda_secret_arns, aws_secretsmanager_secret.proxy_connection_string[0].arn) && !contains(local.lambda_secret_arns, aws_secretsmanager_secret.connection_string.arn)
    error_message = "The Lambda roles must be granted the proxy connection-string secret they read, and no longer the direct one."
  }

  assert {
    condition     = output.rds_proxy_endpoint == aws_db_proxy.this[0].endpoint && output.rds_proxy_arn == aws_db_proxy.this[0].arn && output.runtime_db_connection_secret_arn == aws_secretsmanager_secret.proxy_connection_string[0].arn && output.db_connection_secret_arn == aws_secretsmanager_secret.connection_string.arn
    error_message = "The module must output the proxy endpoint and ARN and the runtime secret, and keep db_connection_secret_arn on the direct secret."
  }
}

run "on_admits_the_egress_isolation_phases" {
  command = plan

  variables {
    enable_rds_proxy                   = true
    enable_customcode_egress_isolation = true
  }

  assert {
    condition     = toset(keys(aws_security_group_rule.rds_proxy_from_clients)) == toset(["lambda", "gp_batch", "gp_batch_provisioning", "gp_batch_execution"])
    error_message = "With custom-code egress isolation, the provisioning and execution security groups must reach the proxy too."
  }
}

run "on_with_an_existing_database_is_rejected" {
  command = plan

  variables {
    enable_rds_proxy              = true
    enable_gp_batch               = false
    enable_control_plane_events   = false
    existing_db_endpoint          = "postgres.example.internal"
    existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"
  }

  expect_failures = [terraform_data.rds_proxy_inputs]
}

run "idle_above_the_ceiling_is_rejected" {
  command = plan

  variables {
    enable_rds_proxy                       = true
    rds_proxy_max_connections_percent      = 40
    rds_proxy_max_idle_connections_percent = 60
  }

  expect_failures = [terraform_data.rds_proxy_inputs]
}
