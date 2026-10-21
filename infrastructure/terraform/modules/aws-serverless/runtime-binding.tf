# Configured resource identities for the agent handoff. Terraform does not
# manufacture an observation receipt: the consumer must independently read the
# live function, alias, API integration and route before accepting this binding.
output "runtime_binding_contract" {
  description = "Credential-free Lambda runtime facts; not a deployment or recovery qualification receipt."
  value = {
    schemaVersion = "honua.runtime-binding/v1"
    runtimeKind   = "aws-lambda"
    targetKind    = "AwsLambda"
    backend       = "honua-gitops-aws-lambda"
    targetId      = local.lambda_target_id
    environment   = var.environment
    platform = {
      accountId = data.aws_caller_identity.current.account_id
      region    = data.aws_region.current.name
      partition = try(split(":", aws_lambda_function.this.arn)[1], null)
    }
    resourceIdentity = {
      functionArn                   = aws_lambda_function.this.arn
      aliasArn                      = aws_lambda_alias.live.arn
      publishedVersion              = aws_lambda_alias.live.function_version
      apiGatewayId                  = aws_apigatewayv2_api.this.id
      apiGatewayRouteId             = aws_apigatewayv2_route.proxy.id
      apiGatewayRouteKey            = aws_apigatewayv2_route.proxy.route_key
      apiGatewayIntegrationId       = aws_apigatewayv2_integration.lambda.id
      apiGatewayIntegrationAliasArn = try(regex("/functions/(arn:[^/]+)/invocations$", aws_apigatewayv2_integration.lambda.integration_uri)[0], null)
      apiGatewayStage               = aws_apigatewayv2_stage.this.name
    }
  }
}
