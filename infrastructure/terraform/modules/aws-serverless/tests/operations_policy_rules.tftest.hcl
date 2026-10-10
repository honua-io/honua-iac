# Operation policy rules (operations_policy_rules).
#
# The server image runs in Production, whose appsettings enable
# Operations:Policy with DefaultDecision Deny, so every typed operation (for
# example service.publish) is denied until the operator authors rules. The
# module renders the rules as indexed Operations__Policy__Rules__<n>__<Field>
# entries on every process that runs the server: the API Lambda, the
# control-plane event Lambdas (which inherit its environment) and the GP Batch
# job definitions. Unset optional fields render nothing.

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
}

mock_provider "random" {}
mock_provider "null" {}

variables {
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"

  image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password = "Synthetic-Terraform-Test-Admin-4721!aA1"

  redis_enabled               = false
  enable_control_plane_events = true
  enable_gp_batch             = true
}

run "no_rules_render_nothing" {
  command = apply

  assert {
    condition     = length([for k in keys(aws_lambda_function.this.environment[0].variables) : k if startswith(k, "Operations__Policy__")]) == 0
    error_message = "With no rules the Lambda must carry no Operations__Policy__ entries."
  }

  assert {
    condition = alltrue([
      for tier, jd in aws_batch_job_definition.gp :
      length([for e in jsondecode(jd.container_properties).environment : e if startswith(e.name, "Operations__Policy__")]) == 0
    ])
    error_message = "With no rules the GP job definitions must carry no Operations__Policy__ entries."
  }
}

run "rules_render_on_every_server_process" {
  command = apply

  variables {
    operations_policy_rules = [
      {
        operation_id = "service.publish"
        role         = "publisher"
        decision     = "Allow"
      },
      {
        operation_id  = "*"
        role          = "operator"
        tier          = "enterprise"
        decision      = "RequireApproval"
        reason        = "Operator changes need a second reviewer."
        approval_lane = "ops-review"
      },
    ]
  }

  assert {
    condition = {
      for k, v in aws_lambda_function.this.environment[0].variables : k => v if startswith(k, "Operations__Policy__")
      } == {
      Operations__Policy__Rules__0__OperationId  = "service.publish"
      Operations__Policy__Rules__0__Role         = "publisher"
      Operations__Policy__Rules__0__Decision     = "Allow"
      Operations__Policy__Rules__1__OperationId  = "*"
      Operations__Policy__Rules__1__Role         = "operator"
      Operations__Policy__Rules__1__Tier         = "enterprise"
      Operations__Policy__Rules__1__Decision     = "RequireApproval"
      Operations__Policy__Rules__1__Reason       = "Operator changes need a second reviewer."
      Operations__Policy__Rules__1__ApprovalLane = "ops-review"
    }
    error_message = "The Lambda must carry exactly the flattened rules, in order, omitting unset fields."
  }

  assert {
    condition = alltrue([
      for fn in [aws_lambda_function.control_plane_reconcile[0], aws_lambda_function.control_plane_backstop[0], aws_lambda_function.control_plane_tick[0]] :
      { for k, v in fn.environment[0].variables : k => v if startswith(k, "Operations__Policy__") } ==
      { for k, v in aws_lambda_function.this.environment[0].variables : k => v if startswith(k, "Operations__Policy__") }
    ])
    error_message = "The control-plane event functions must inherit the same policy rules as the API Lambda."
  }

  assert {
    condition = alltrue([
      for tier, jd in aws_batch_job_definition.gp :
      { for e in jsondecode(jd.container_properties).environment : e.name => e.value if startswith(e.name, "Operations__Policy__") } ==
      { for k, v in aws_lambda_function.this.environment[0].variables : k => v if startswith(k, "Operations__Policy__") }
    ])
    error_message = "Every GP job-definition tier must carry the same policy rules as the Lambda."
  }
}

run "operation_id_defaults_to_any_operation" {
  command = apply

  variables {
    operations_policy_rules = [{ decision = "Deny", role = "viewer" }]
  }

  assert {
    condition     = aws_lambda_function.this.environment[0].variables["Operations__Policy__Rules__0__OperationId"] == "*"
    error_message = "An omitted operation_id must render as the \"*\" wildcard."
  }
}

run "unknown_decision_is_rejected" {
  command = plan

  variables {
    operations_policy_rules = [{ operation_id = "service.publish", decision = "Permit" }]
  }

  expect_failures = [var.operations_policy_rules]
}
