mock_provider "aws" {}

variables {
  honua_image_uri      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server:test"
  honua_admin_password = "01234567890123456789012345678901"
  db_password          = "example-db-password"
}

override_module {
  target = module.stack.module.honua
  outputs = {
    environment                      = "it"
    aws_region                       = "us-east-1"
    api_endpoint                     = "https://honua-lambda.example.test"
    lambda_function_name             = "honua-lambda"
    lambda_function_arn              = "arn:aws:lambda:us-east-1:123456789012:function:honua-lambda"
    lambda_function_version          = "42"
    lambda_alias_name                = "live"
    lambda_alias_arn                 = "arn:aws:lambda:us-east-1:123456789012:function:honua-lambda:live"
    lambda_alias_invoke_arn          = "arn:aws:apigateway:us-east-1::/restapis/test/stages/live"
    lambda_alias_function_version    = "42"
    control_plane_target_kind        = "aws-lambda-alias"
    control_plane_backend_name       = "aws-serverless"
    control_plane_target_id          = "it-honua-lambda-live"
    control_plane_target_name        = "honua-lambda"
    control_plane_target_resource_id = "arn:aws:lambda:us-east-1:123456789012:function:honua-lambda:live"
    control_plane_telemetry_policy   = "prometheus"
    control_plane_current_revision   = "42"
    control_plane_desired_revision   = "43"
    db_endpoint                      = "honua-db.internal"
    redis_connection_string          = "rediss://cache.example.test:6379"
  }
}

run "serverless_output_groups_are_stable" {
  command = plan

  assert {
    condition     = output.infrastructure_outputs.workload.alias_name == "live"
    error_message = "aws-serverless example should expose Lambda alias details through infrastructure_outputs."
  }

  assert {
    condition     = output.honua_integration_outputs.control_plane.current_revision == "42"
    error_message = "aws-serverless example should retain rollout metadata in honua_integration_outputs."
  }

  assert {
    condition     = output.validation_contract.platform.capabilities.deploy_plan == true
    error_message = "aws-serverless validation contract should retain deploy-plan support."
  }
}
