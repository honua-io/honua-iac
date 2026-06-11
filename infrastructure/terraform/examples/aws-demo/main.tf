###############################################################################
# Phase-A Honua Demo Environment — demo.honua.io
#
# Single Fargate task + RDS db.t4g.small + ALB/HTTPS + WAFv2 rate-limiting.
# No Redis (single task does not need distributed cache).
# See README.md for DNS prerequisites before applying.
###############################################################################

locals {
  common_tags = merge({
    Project     = "honua-server"
    Environment = var.environment
    ManagedBy   = "terraform"
    Purpose     = "public-demo"
  }, var.tags)
}

# ---------------------------------------------------------------------------
# WAFv2 rate-limiting Web ACL
# The aws-ecs module accepts a caller-provisioned waf_web_acl_arn.
# Association with the ALB is handled by the module; we only provision the ACL
# and its rules here.
# ---------------------------------------------------------------------------

resource "aws_wafv2_regex_pattern_set" "api_paths" {
  name  = "${var.name_prefix}-api-paths"
  scope = "REGIONAL"

  regular_expression {
    regex_string = "^/(rest|ogc|odata)/"
  }

  tags = local.common_tags
}

resource "aws_wafv2_web_acl" "demo" {
  name        = "${var.name_prefix}-rate-limit"
  description = "WAFv2 rate-limiting ACL for the demo.honua.io demo environment."
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  custom_response_body {
    key          = "rate-limited"
    content_type = "APPLICATION_JSON"
    content      = "{\"error\":\"rate_limited\",\"message\":\"Too many requests. Retry after 60 seconds.\"}"
  }

  rule {
    name     = "api-rate-limit"
    priority = 1

    action {
      block {
        custom_response {
          response_code            = 429
          custom_response_body_key = "rate-limited"

          response_header {
            name  = "Retry-After"
            value = "60"
          }
        }
      }
    }

    statement {
      rate_based_statement {
        limit              = var.waf_api_limit_per_5m
        aggregate_key_type = "IP"

        scope_down_statement {
          regex_pattern_set_reference_statement {
            arn = aws_wafv2_regex_pattern_set.api_paths.arn

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-api-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "admin-rate-limit"
    priority = 2

    action {
      block {
        custom_response {
          response_code            = 429
          custom_response_body_key = "rate-limited"

          response_header {
            name  = "Retry-After"
            value = "60"
          }
        }
      }
    }

    statement {
      rate_based_statement {
        limit              = var.waf_admin_limit_per_5m
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            positional_constraint = "STARTS_WITH"
            search_string         = "/admin/"

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-admin-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-rate-limit"
    sampled_requests_enabled   = true
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Honua Server — ECS/Fargate
# ---------------------------------------------------------------------------

module "honua" {
  source = "../../modules/aws-ecs"

  # Identity
  name_prefix = var.name_prefix
  environment = var.environment

  # Container sizing — Phase A: single small task
  image                 = var.honua_image
  task_cpu_architecture = "ARM64" # Graviton — cheaper and faster for .NET AOT
  container_cpu         = 512     # 0.5 vCPU
  container_memory      = 1024    # 1 GiB
  desired_count         = 1
  max_capacity          = 1 # demo: no autoscale scale-out

  # Secrets
  admin_password = var.honua_admin_password

  # Database — db.t4g.small + PostGIS
  db_instance_class    = "db.t4g.small"
  db_allocated_storage = 20
  db_engine_version    = "15"
  db_password          = var.db_password
  db_require_ssl       = true
  db_multi_az          = false # single-AZ for demo cost
  enable_postgis       = true  # Required — Honua needs PostGIS + PostGIS Raster

  # Redis — disabled (single task, no distributed cache needed)
  redis_enabled = false

  # Networking — single NAT GW for cost savings on non-prod
  enable_nat_gateway = true
  single_nat_gateway = true
  assign_public_ip   = false

  # HTTPS — ACM cert auto-provisioned + Route53 alias A record created
  domain_name                 = "demo.honua.io"
  route53_zone_id             = var.route53_zone_id
  domain_alias_record_enabled = true
  alb_enable_http_redirect    = true
  alb_deletion_protection     = true
  alb_drop_invalid_headers    = true

  # Public internet access (read-mostly demo).
  # Note: the aws-ecs module uses cidr_blocks (IPv4 only); IPv6 is not yet
  # supported by the module's security-group ingress rules.
  allow_https_ingress_cidrs = ["0.0.0.0/0"]
  allow_http_ingress_cidrs  = ["0.0.0.0/0"]

  # ALB access logs (use auto-created bucket)
  alb_access_logs_enabled       = true
  alb_access_logs_force_destroy = false

  # WAF — pass the ACL we provisioned above
  waf_web_acl_arn = aws_wafv2_web_acl.demo.arn

  # Observability
  log_retention_days        = 90 # shorter for demo to contain cost
  enable_container_insights = true

  # Demo-specific environment variables
  additional_env = {
    HONUA_SERVE_API_DOCS          = "true"
    HONUA_SERVE_STAC_DEMO         = "true"
    MultiTenancy__Enabled         = "true"
    MultiTenancy__DefaultTenantId = "public"
  }

  tags = local.common_tags
}
