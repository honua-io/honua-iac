# Per-cell custom domain for the Lambda cells (owner decision 11, 2026-10-10;
# honua-iac#223, honua-io/honua-release#450 and #282).
#
# The honua-site top-demo scenarios (S9) pin a CSP that admits only HTTPS
# honua.io backends, so a Lambda cell needs the same <run label>.cert.demo.honua.io
# domain the ECS cells get from modules/aws-ecs (iac#229 / release#511):
# domain_name + route53_zone_id -> a DNS-validated ACM certificate, a regional
# TLS 1.2 API Gateway custom domain mapped to the $default stage, a Route53
# alias, and service_url on https://<domain_name>. With neither input set the
# module must create none of it and keep service_url on execute-api.
#
# The release teardown verifies the cell's own certificate and DNS records are
# gone, so every one of them must be module-owned (counted here), never a data
# source lookup. Mocked providers; no AWS calls.

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

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:honua-mock:*"
    }
  }

  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      arn           = "arn:aws:apigateway:us-east-1::/apis/abcdefghij"
      api_endpoint  = "https://abcdefghij.execute-api.us-east-1.amazonaws.com"
      execution_arn = "arn:aws:execute-api:us-east-1:123456789012:abcdefghij"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-mock-AbCdEf"
    }
  }

  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "random" {}
mock_provider "null" {}

variables {
  # Recommended in Production; unset only plans with a check warning.
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"

  image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password = "Synthetic-Terraform-Test-Admin-4721!aA1"
  redis_enabled  = false
}

run "no_domain_creates_nothing_and_keeps_execute_api" {
  command = apply

  assert {
    condition = (
      length(aws_acm_certificate.api) == 0 &&
      length(aws_route53_record.api_cert_validation) == 0 &&
      length(aws_acm_certificate_validation.api) == 0 &&
      length(aws_apigatewayv2_domain_name.this) == 0 &&
      length(aws_apigatewayv2_api_mapping.this) == 0 &&
      length(aws_route53_record.api_alias) == 0
    )
    error_message = "Without domain_name and route53_zone_id the module must create no certificate, validation record, custom domain, mapping or alias."
  }

  assert {
    condition     = output.service_url == "https://abcdefghij.execute-api.us-east-1.amazonaws.com" && output.service_url == output.api_endpoint
    error_message = "Without a custom domain service_url must be the execute-api endpoint."
  }

  assert {
    condition     = output.custom_domain_url == null && output.custom_domain_name == null && output.custom_domain_alias_fqdn == null && output.custom_domain_certificate_arn == null
    error_message = "Without a custom domain the custom-domain outputs must be null."
  }

  assert {
    condition     = !contains(keys(local.lambda_environment), "HostValidation__AllowedHosts__1")
    error_message = "Without a custom domain no extra host-validation entry may be emitted (4 KB Lambda environment budget)."
  }
}

run "domain_creates_certificate_custom_domain_mapping_and_alias" {
  command = apply

  variables {
    domain_name     = "honuarawsse380460-it.cert.demo.honua.io"
    route53_zone_id = "Z089181827C9GKIKHXUTT"
  }

  override_resource {
    target = aws_acm_certificate.api
    values = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [{
        domain_name           = "honuarawsse380460-it.cert.demo.honua.io"
        resource_record_name  = "_abc.honuarawsse380460-it.cert.demo.honua.io."
        resource_record_type  = "CNAME"
        resource_record_value = "_def.acm-validations.aws."
      }]
    }
  }

  override_resource {
    target = aws_apigatewayv2_domain_name.this
    values = {
      id  = "honuarawsse380460-it.cert.demo.honua.io"
      arn = "arn:aws:apigateway:us-east-1::/domainnames/honuarawsse380460-it.cert.demo.honua.io"
      domain_name_configuration = [{
        certificate_arn    = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
        endpoint_type      = "REGIONAL"
        security_policy    = "TLS_1_2"
        target_domain_name = "d-abcdefghij.execute-api.us-east-1.amazonaws.com"
        hosted_zone_id     = "Z1UJRXOUMOOFQ8"
      }]
    }
  }

  assert {
    condition     = aws_acm_certificate.api[0].domain_name == "honuarawsse380460-it.cert.demo.honua.io" && aws_acm_certificate.api[0].validation_method == "DNS"
    error_message = "The module must request a DNS-validated ACM certificate for domain_name."
  }

  assert {
    condition = (
      length(aws_route53_record.api_cert_validation) == 1 &&
      aws_route53_record.api_cert_validation["honuarawsse380460-it.cert.demo.honua.io"].zone_id == "Z089181827C9GKIKHXUTT" &&
      aws_route53_record.api_cert_validation["honuarawsse380460-it.cert.demo.honua.io"].type == "CNAME" &&
      length(aws_acm_certificate_validation.api) == 1
    )
    error_message = "The certificate's validation record must be created in route53_zone_id and the validation awaited."
  }

  assert {
    condition = (
      aws_apigatewayv2_domain_name.this[0].domain_name == "honuarawsse380460-it.cert.demo.honua.io" &&
      aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].endpoint_type == "REGIONAL" &&
      aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].security_policy == "TLS_1_2"
    )
    error_message = "The API Gateway custom domain must be REGIONAL with the TLS 1.2 policy."
  }

  assert {
    condition = (
      aws_apigatewayv2_api_mapping.this[0].api_id == aws_apigatewayv2_api.this.id &&
      aws_apigatewayv2_api_mapping.this[0].stage == aws_apigatewayv2_stage.this.id &&
      aws_apigatewayv2_api_mapping.this[0].domain_name == aws_apigatewayv2_domain_name.this[0].id
    )
    error_message = "The custom domain must be mapped to the HTTP API's $default stage."
  }

  assert {
    condition = (
      aws_route53_record.api_alias[0].zone_id == "Z089181827C9GKIKHXUTT" &&
      aws_route53_record.api_alias[0].name == "honuarawsse380460-it.cert.demo.honua.io" &&
      aws_route53_record.api_alias[0].type == "A" &&
      one(aws_route53_record.api_alias[0].alias).name == "d-abcdefghij.execute-api.us-east-1.amazonaws.com" &&
      one(aws_route53_record.api_alias[0].alias).zone_id == "Z1UJRXOUMOOFQ8"
    )
    error_message = "The Route53 alias must point domain_name at the API Gateway custom domain's regional target."
  }

  assert {
    condition     = output.service_url == "https://honuarawsse380460-it.cert.demo.honua.io" && output.custom_domain_url == "https://honuarawsse380460-it.cert.demo.honua.io"
    error_message = "service_url / custom_domain_url must be the https custom domain."
  }

  assert {
    condition     = output.api_endpoint == "https://abcdefghij.execute-api.us-east-1.amazonaws.com"
    error_message = "api_endpoint must stay the execute-api endpoint, which remains enabled."
  }

  assert {
    condition     = output.custom_domain_certificate_arn == aws_acm_certificate.api[0].arn && output.custom_domain_alias_fqdn == aws_route53_record.api_alias[0].fqdn
    error_message = "The module-owned certificate and alias must be exposed for the release teardown check."
  }

  # API Gateway passes the client's Host (the custom domain) through the
  # payload-2.0 event and Lambda Web Adapter replays it; honua-server rejects a
  # host outside HostValidation:AllowedHosts with 400.
  assert {
    condition = (
      local.lambda_environment["HostValidation__AllowedHosts__0"] == "*.execute-api.us-east-1.amazonaws.com" &&
      local.lambda_environment["HostValidation__AllowedHosts__1"] == "honuarawsse380460-it.cert.demo.honua.io"
    )
    error_message = "The Lambda must allowlist the custom domain in host validation alongside execute-api."
  }

  assert {
    condition     = local.lambda_environment["SecurityHeaders__HstsHttpsOnly"] == "false" && !contains(keys(local.lambda_environment), "ASPNETCORE_FORWARDEDHEADERS_ENABLED")
    error_message = "HSTS is already emitted behind API Gateway; the custom domain adds no other environment entry."
  }
}

run "an_explicit_allowed_host_is_not_duplicated" {
  command = plan

  variables {
    domain_name              = "honuarawsse380460-it.cert.demo.honua.io"
    route53_zone_id          = "Z089181827C9GKIKHXUTT"
    additional_allowed_hosts = ["*.lambda-url.us-east-1.on.aws", "honuarawsse380460-it.cert.demo.honua.io"]
  }

  assert {
    condition = (
      local.lambda_environment["HostValidation__AllowedHosts__1"] == "*.lambda-url.us-east-1.on.aws" &&
      local.lambda_environment["HostValidation__AllowedHosts__2"] == "honuarawsse380460-it.cert.demo.honua.io" &&
      !contains(keys(local.lambda_environment), "HostValidation__AllowedHosts__3")
    )
    error_message = "Operator-supplied allowed hosts keep their order and the custom domain is not appended twice."
  }
}

run "half_a_domain_configuration_warns_and_creates_nothing" {
  command = plan

  variables {
    domain_name = "honuarawsse380460-it.cert.demo.honua.io"
  }

  expect_failures = [check.custom_domain_inputs]

  assert {
    condition     = length(aws_apigatewayv2_domain_name.this) == 0 && length(aws_acm_certificate.api) == 0
    error_message = "domain_name without route53_zone_id must not create a certificate or custom domain."
  }
}
