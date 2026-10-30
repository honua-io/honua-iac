# TLS on the chart's Service terminates at the AWS load balancer and the
# backend protocol is HTTP (ingress.tf). honua-server then sees an http
# request and, with SecurityHeaders:HstsHttpsOnly left at its default, omits
# Strict-Transport-Security on the public https:// endpoint. The managed
# certificate path must render the same override modules/aws-ecs and
# modules/aws-serverless already set. A plain-HTTP Service, including one
# that only sets public_base_url, must not.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
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

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_region" {
    defaults = {
      id     = "us-east-1"
      name   = "us-east-1"
      region = "us-east-1"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "tls" {}
mock_provider "time" {}
mock_provider "cloudinit" {}
mock_provider "null" {}
mock_provider "random" {}

override_resource {
  target          = aws_secretsmanager_secret.db_connection
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-db-AAAAAA"
  }
}

override_resource {
  target          = aws_secretsmanager_secret.admin_password
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-admin-BBBBBB"
  }
}

override_resource {
  target          = aws_secretsmanager_secret.master_key
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-connection-encryption-CCCCCC"
  }
}

override_resource {
  target          = aws_secretsmanager_secret.redis_connection
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-redis-DDDDDD"
  }
}

variables {
  name_prefix = "honua"
  environment = "test"

  cluster_secret_encryption_enabled = false
  audit_chain_key_secret_arn        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
}

run "managed_certificate_emits_hsts_over_the_http_backend" {
  command = plan

  variables {
    domain_name     = "cell.cert.demo.example.com"
    route53_zone_id = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition = (
      output.ingress_service_annotations["service.beta.kubernetes.io/aws-load-balancer-backend-protocol"] == "http" &&
      output.chart_config_env["SecurityHeaders__HstsHttpsOnly"] == "false" &&
      output.honua_server_environment["SecurityHeaders__HstsHttpsOnly"] == "false"
    )
    error_message = "A managed certificate terminates TLS at the load balancer and forwards HTTP, so chart_config_env must set SecurityHeaders__HstsHttpsOnly=false."
  }
}

run "plain_http_service_does_not_force_hsts" {
  command = plan

  assert {
    condition     = !contains(keys(output.chart_config_env), "SecurityHeaders__HstsHttpsOnly")
    error_message = "Without a managed certificate the Service is plain HTTP and must not force HSTS."
  }
}

run "public_base_url_alone_does_not_force_hsts" {
  command = plan

  variables {
    public_base_url = "https://gis.example.com"
  }

  assert {
    condition = (
      output.chart_config_env["Public__BaseUrl"] == "https://gis.example.com" &&
      !contains(keys(output.chart_config_env), "SecurityHeaders__HstsHttpsOnly") &&
      length(aws_acm_certificate.this) == 0
    )
    error_message = "public_base_url alone is not this module's TLS termination, so it must not force HSTS."
  }
}
