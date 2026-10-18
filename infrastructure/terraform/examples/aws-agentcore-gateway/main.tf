provider "aws" {
  region                      = var.region
  skip_credentials_validation = !var.enabled
  skip_requesting_account_id  = !var.enabled
  skip_metadata_api_check     = !var.enabled
}

module "honua_gateway" {
  source                                    = "../../modules/aws-agentcore-gateway"
  enabled                                   = var.enabled
  name                                      = var.name
  honua_base_url                            = var.honua_base_url
  identity                                  = var.identity
  private_origin_resource_configuration_arn = var.private_origin_resource_configuration_arn
  request_schema_json                       = var.request_schema_json
  cedar_policy_templates                    = var.cedar_policy_templates
  tags                                      = var.tags
}

output "gateway_binding" { value = module.honua_gateway.gateway_binding }
