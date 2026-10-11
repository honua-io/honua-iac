# Public:BaseUrl and customer domains for the Lambda cells
# (honua-io/honua-release#450, #282).
#
# honua-server builds absolute links (publication URLs, OGC/STAC self links,
# admin OIDC redirect URIs) only from Public:BaseUrl / PUBLIC_BASE_URL and
# falls back to a loopback origin without it. Customers run Honua on their own
# domains, so the custom domain must work on any TLD (including punycode) and
# set Public__BaseUrl=https://<domain_name>, with an explicit public_base_url
# override, without shadowing a value the operator put in additional_env.
# Mocked providers; no AWS calls.

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

run "customer_domains_on_any_tld_are_accepted" {
  command = plan

  override_resource {
    target          = aws_acm_certificate.api[0]
    override_during = plan
    values = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [{
        domain_name           = "maps.city-of-example.gov.au"
        resource_record_name  = "_abc.maps.city-of-example.gov.au."
        resource_record_type  = "CNAME"
        resource_record_value = "_def.acm-validations.aws."
      }]
    }
  }

  variables {
    domain_name     = "maps.city-of-example.gov.au"
    route53_zone_id = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition = (
      local.lambda_environment["Public__BaseUrl"] == "https://maps.city-of-example.gov.au" &&
      local.lambda_environment["HostValidation__AllowedHosts__1"] == "maps.city-of-example.gov.au"
    )
    error_message = "A customer domain must get the same Public__BaseUrl and host-validation entry as a certification cell."
  }
}

run "punycode_tld_is_accepted" {
  command = plan

  override_resource {
    target          = aws_acm_certificate.api[0]
    override_during = plan
    values = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [{
        domain_name           = "karte.example.xn--p1ai"
        resource_record_name  = "_abc.karte.example.xn--p1ai."
        resource_record_type  = "CNAME"
        resource_record_value = "_def.acm-validations.aws."
      }]
    }
  }

  variables {
    domain_name     = "karte.example.xn--p1ai"
    route53_zone_id = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition     = local.lambda_environment["Public__BaseUrl"] == "https://karte.example.xn--p1ai"
    error_message = "An internationalized (xn--) TLD is a valid customer domain."
  }
}

run "upper_case_domain_is_rejected" {
  command = plan

  variables {
    domain_name     = "GIS.Example.com"
    route53_zone_id = "Z0123456789ABCDEFGHIJ"
  }

  expect_failures = [var.domain_name]
}

run "explicit_public_base_url_wins_over_the_domain" {
  command = plan

  override_resource {
    target          = aws_acm_certificate.api[0]
    override_during = plan
    values = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [{
        domain_name           = "api.example.org"
        resource_record_name  = "_abc.api.example.org."
        resource_record_type  = "CNAME"
        resource_record_value = "_def.acm-validations.aws."
      }]
    }
  }

  variables {
    domain_name     = "api.example.org"
    route53_zone_id = "Z0123456789ABCDEFGHIJ"
    public_base_url = "https://maps.example.org/"
  }

  assert {
    condition     = local.lambda_environment["Public__BaseUrl"] == "https://maps.example.org" && output.service_url == "https://api.example.org"
    error_message = "public_base_url (for example a CDN on the customer's domain) must win over domain_name, trailing slash trimmed; service_url stays the API domain."
  }
}

run "public_base_url_without_a_domain" {
  command = plan

  variables {
    public_base_url = "https://gis.example.com/honua"
  }

  assert {
    condition     = local.lambda_environment["Public__BaseUrl"] == "https://gis.example.com/honua" && !contains(keys(local.lambda_environment), "HostValidation__AllowedHosts__1")
    error_message = "public_base_url alone renders Public__BaseUrl and nothing else."
  }
}

run "operator_additional_env_value_is_kept" {
  command = plan

  override_resource {
    target          = aws_acm_certificate.api[0]
    override_during = plan
    values = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [{
        domain_name           = "api.example.org"
        resource_record_name  = "_abc.api.example.org."
        resource_record_type  = "CNAME"
        resource_record_value = "_def.acm-validations.aws."
      }]
    }
  }

  variables {
    domain_name     = "api.example.org"
    route53_zone_id = "Z0123456789ABCDEFGHIJ"
    additional_env  = { PUBLIC_BASE_URL = "https://front.example.org" }
  }

  assert {
    condition = (
      !contains(keys(local.lambda_environment), "Public__BaseUrl") &&
      local.lambda_environment["PUBLIC_BASE_URL"] == "https://front.example.org" &&
      output.public_base_url == null
    )
    error_message = "A PUBLIC_BASE_URL / Public__BaseUrl in additional_env must not be shadowed (the server reads Public:BaseUrl first)."
  }
}

run "public_base_url_and_additional_env_conflict_warns" {
  command = plan

  variables {
    public_base_url = "https://maps.example.com"
    additional_env  = { Public__BaseUrl = "https://front.example.org" }
  }

  expect_failures = [check.public_base_url_single_source]
}

run "bare_host_public_base_url_is_rejected" {
  command = plan

  variables {
    public_base_url = "gis.example.com"
  }

  expect_failures = [var.public_base_url]
}
