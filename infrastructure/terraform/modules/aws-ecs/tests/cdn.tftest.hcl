mock_provider "aws" {
  source = "./tests/mocks/aws"
}

mock_provider "random" {
  mock_resource "random_password" {
    defaults = { result = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  }
}
mock_provider "null" {}

variables {
  domain_name              = "maps.example.com"
  alb_certificate_arn      = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  alb_enable_http_redirect = false
  enable_postgis           = false
  cdn = {
    viewer_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  }

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

run "cdn_without_console_caches_only_what_the_origin_allows" {
  command = apply

  assert {
    condition     = aws_cloudfront_cache_policy.api[0].min_ttl == 0 && aws_cloudfront_cache_policy.api[0].default_ttl == 0 && aws_cloudfront_cache_policy.api[0].max_ttl == 31536000
    error_message = "Only origin Cache-Control may decide what is stored: minimum and default lifetime 0, maximum one year."
  }
  assert {
    condition     = one(aws_cloudfront_cache_policy.api[0].parameters_in_cache_key_and_forwarded_to_origin).enable_accept_encoding_gzip && one(aws_cloudfront_cache_policy.api[0].parameters_in_cache_key_and_forwarded_to_origin).enable_accept_encoding_brotli
    error_message = "The cached behavior must key and compress on Gzip and Brotli."
  }
  assert {
    condition = toset(one(one(one(aws_cloudfront_cache_policy.api[0].parameters_in_cache_key_and_forwarded_to_origin).headers_config).headers).items) == toset([
      "Authorization", "X-API-Key", "X-Esri-Authorization", "X-Honua-Embed-Key", "X-Honua-Token", "X-Honua-Tenant",
      "Origin", "Accept", "Accept-Language", "Prefer",
    ])
    error_message = "The cache key must hold every credential header and the representation headers, and nothing else."
  }
  assert {
    condition     = toset(one(one(one(aws_cloudfront_cache_policy.api[0].parameters_in_cache_key_and_forwarded_to_origin).cookies_config).cookies).items) == toset(["honua_admin_session", "honua_admin_login", "honua_cache_bypass"])
    error_message = "The cache key must hold the admin session cookies and the bypass marker, and no other cookie."
  }
  assert {
    condition = (
      one(one(aws_cloudfront_distribution.cdn[0].default_cache_behavior).function_association).event_type == "viewer-request" &&
      one(one(aws_cloudfront_distribution.cdn[0].default_cache_behavior).function_association).function_arn == aws_cloudfront_function.cache_bypass_marker[0].arn &&
      strcontains(aws_cloudfront_function.cache_bypass_marker[0].code, "var bypassHeaders = [\"x-honua-job-id\",\"x-forwarded-client-cert\"];") &&
      strcontains(aws_cloudfront_function.cache_bypass_marker[0].code, "var markerCookie = 'honua_cache_bypass';")
    )
    error_message = "Credential headers beyond the ten-header cache-policy limit must give the request a cache key of its own."
  }
  assert {
    condition     = one(one(aws_cloudfront_cache_policy.api[0].parameters_in_cache_key_and_forwarded_to_origin).query_strings_config).query_string_behavior == "all"
    error_message = "Every query parameter, including the token and key credentials, must be part of the cache key."
  }
  assert {
    condition = (
      one(aws_cloudfront_distribution.cdn[0].default_cache_behavior).target_origin_id == "api" &&
      one(aws_cloudfront_distribution.cdn[0].default_cache_behavior).cache_policy_id == aws_cloudfront_cache_policy.api[0].id &&
      one(aws_cloudfront_distribution.cdn[0].default_cache_behavior).origin_request_policy_id == "216adef6-5c7f-47e4-b989-5492eafa07d3" &&
      one(aws_cloudfront_distribution.cdn[0].default_cache_behavior).compress &&
      toset(one(aws_cloudfront_distribution.cdn[0].default_cache_behavior).cached_methods) == toset(["GET", "HEAD"])
    )
    error_message = "API reads use the origin-controlled cache policy, forward every viewer value, and cache GET and HEAD only."
  }
  assert {
    condition = alltrue([
      for pattern in ["*/admin", "*/admin/*", "/sharing/rest/generateToken*", "/sharing/rest/oauth2/*", "/oauth/*", "/signin-oidc*", "/saml/*", "/scim/*", "/mcp*", "/hubs/*"] :
      length([
        for behavior in aws_cloudfront_distribution.cdn[0].ordered_cache_behavior : behavior
        if behavior.path_pattern == pattern && behavior.target_origin_id == "api" && behavior.cache_policy_id == "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" && behavior.origin_request_policy_id == "216adef6-5c7f-47e4-b989-5492eafa07d3"
      ]) == 1
    ])
    error_message = "Admin, sign-in, provisioning, agent and hub paths must stay on the caching-disabled behavior."
  }
  assert {
    condition     = length(aws_cloudfront_distribution.cdn[0].ordered_cache_behavior) == 10 && length(aws_cloudfront_distribution.cdn[0].origin) == 1 && length(aws_s3_bucket.deployment) == 0
    error_message = "Without a static Console the distribution has the load balancer as its only origin."
  }
  assert {
    condition     = aws_cloudfront_distribution.cdn[0].http_version == "http2and3" && aws_cloudfront_distribution.cdn[0].is_ipv6_enabled && length(aws_cloudfront_distribution.cdn[0].logging_config) == 0
    error_message = "The distribution serves HTTP/2 and HTTP/3 over IPv4 and IPv6; logging stays off until configured."
  }
  assert {
    condition = (
      toset([for response in aws_cloudfront_distribution.cdn[0].custom_error_response : response.error_code]) == toset([400, 403, 404, 405, 414, 416, 500, 501, 502, 503, 504]) &&
      alltrue([for response in aws_cloudfront_distribution.cdn[0].custom_error_response : response.error_caching_min_ttl == 0 && response.response_page_path == null])
    )
    error_message = "No error status may be held at the edge longer than the origin allows, and no error body is replaced."
  }
  assert {
    condition = (
      aws_lb_listener.https[0].default_action[0].type == "fixed-response" && aws_lb_listener.https[0].default_action[0].fixed_response[0].status_code == "403" &&
      length(aws_security_group.alb.ingress) == 1 && length(one(aws_security_group.alb.ingress).cidr_blocks) == 0 && length(one(aws_security_group.alb.ingress).prefix_list_ids) == 1 &&
      aws_lb_listener_rule.cloudfront[0].priority == 1 &&
      one(one(one(aws_lb_listener_rule.cloudfront[0].condition).http_header).values) == one([for origin in aws_cloudfront_distribution.cdn[0].origin : one(origin.custom_header).value])
    )
    error_message = "Direct load-balancer requests must be refused: CloudFront prefix list only, 403 by default, and the origin secret on the forwarding rule."
  }
  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.cdn_invalidation[0].policy).Statement) == 1 &&
      toset(jsondecode(aws_iam_role_policy.cdn_invalidation[0].policy).Statement[0].Action) == toset(["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]) &&
      jsondecode(aws_iam_role_policy.cdn_invalidation[0].policy).Statement[0].Resource == [aws_cloudfront_distribution.cdn[0].arn] &&
      aws_iam_role_policy.cdn_invalidation[0].role == aws_iam_role.task.id
    )
    error_message = "The task role may create and read invalidations on this distribution only."
  }
  assert {
    condition     = length([for variable in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : variable if variable.name == "SharedCache__CloudFront__DistributionId" && variable.value == aws_cloudfront_distribution.cdn[0].id]) == 1
    error_message = "The server must receive the distribution id it invalidates."
  }
  assert {
    condition     = output.cdn.distribution_id == aws_cloudfront_distribution.cdn[0].id && output.static_console == null
    error_message = "The cdn output identifies the distribution without a static Console."
  }
}

run "cdn_with_console_and_access_logs" {
  command = apply
  variables {
    cdn = {
      viewer_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      price_class            = "PriceClass_All"
      access_logs            = { bucket_domain_name = "edge-logs.s3.amazonaws.com", prefix = "maps/" }
    }
    static_console = {
      viewer_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      bundle_version         = "rc.2"
    }
  }

  assert {
    condition     = aws_cloudfront_cache_policy.console_assets[0].min_ttl == 0 && aws_cloudfront_cache_policy.console_assets[0].default_ttl == 0 && aws_cloudfront_cache_policy.console_assets[0].max_ttl == 31536000
    error_message = "Console framework files are stored only when their object metadata says so."
  }
  assert {
    condition = (
      [for behavior in aws_cloudfront_distribution.cdn[0].ordered_cache_behavior : behavior.path_pattern if behavior.target_origin_id == "console"] == ["/console/_framework/*", "/console", "/console/*"] &&
      alltrue([for behavior in aws_cloudfront_distribution.cdn[0].ordered_cache_behavior : behavior.cache_policy_id == aws_cloudfront_cache_policy.console_assets[0].id && behavior.compress if behavior.path_pattern == "/console/_framework/*"]) &&
      alltrue([for behavior in aws_cloudfront_distribution.cdn[0].ordered_cache_behavior : behavior.cache_policy_id == "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" if contains(["/console", "/console/*"], behavior.path_pattern)])
    )
    error_message = "Framework files precede the Console catch-all; the entry document and runtime configuration are never cached."
  }
  assert {
    condition     = one(aws_cloudfront_distribution.cdn[0].logging_config).bucket == "edge-logs.s3.amazonaws.com" && one(aws_cloudfront_distribution.cdn[0].logging_config).prefix == "maps/" && !one(aws_cloudfront_distribution.cdn[0].logging_config).include_cookies
    error_message = "Access logs go to the configured bucket without cookies."
  }
  assert {
    condition     = aws_cloudfront_distribution.cdn[0].price_class == "PriceClass_All" && output.static_console.distribution_id == output.cdn.distribution_id
    error_message = "The Console and the API share one distribution."
  }
}

run "canary_behind_cdn_keeps_weights_and_forced_route" {
  command = apply
  variables {
    deployment_mode                           = "MultiNode"
    redis_enabled                             = true
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:key-ring-AbC123"
    file_storage_provider                     = "AwsS3"
    file_storage_aws_s3_create_bucket         = true
    canary_enabled                            = true
    canary_weight_percentage                  = 10
  }

  assert {
    condition = (
      toset([for group in one(one(aws_lb_listener_rule.cloudfront[0].action).forward).target_group : group.weight]) == toset([90, 10]) &&
      one(one(one(aws_lb_listener_rule.cloudfront[0].condition).http_header).values) == one([for origin in aws_cloudfront_distribution.cdn[0].origin : one(origin.custom_header).value])
    )
    error_message = "The rule that admits CloudFront must split traffic with the configured primary and canary weights."
  }
  assert {
    condition = (
      aws_lb_listener_rule.https_canary[0].priority < aws_lb_listener_rule.cloudfront[0].priority &&
      toset([for condition in aws_lb_listener_rule.https_canary[0].condition : one(condition.http_header).http_header_name]) == toset(["X-Honua-Canary", "X-Honua-Origin"]) &&
      aws_lb_listener.https[0].default_action[0].type == "fixed-response"
    )
    error_message = "The forced canary route is evaluated first and still requires the origin secret, so the load balancer stays closed."
  }
  assert {
    condition     = strcontains(aws_cloudfront_function.cache_bypass_marker[0].code, "var bypassHeaders = [\"x-honua-job-id\",\"x-forwarded-client-cert\",\"x-honua-canary\"];")
    error_message = "A request forced onto the canary must never share a cache entry with weighted traffic."
  }
}

run "controller_owned_rollout_behind_cdn_stays_closed" {
  command = apply
  variables {
    deployment_mode                           = "MultiNode"
    desired_count                             = 2
    max_capacity                              = 2
    redis_connection_string                   = "redis.example.internal:6379,password=test,ssl=true"
    redis_connection_cidrs                    = ["10.0.0.0/16"]
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:key-ring-AbC123"
    file_storage_provider                     = "AwsS3"
    file_storage_aws_s3_bucket_name           = "honua-test-files"
    canary_enabled                            = true
    deployment_safety = {
      controller_role_name       = "retained-controller"
      telemetry_connection_id    = "cert-prometheus"
      prometheus_canary_job      = "cert-cell-canary"
      functional_probe_url       = "https://candidate.example.com/fixture"
      functional_expected_sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    }
  }

  assert {
    condition = (
      length(aws_lb_listener_rule.cloudfront) == 0 &&
      length([for condition in aws_lb_listener_rule.protected_rollout[0].condition : condition if length(condition.http_header) == 1 && try(one(condition.http_header).http_header_name, "") == "X-Honua-Origin"]) == 1 &&
      aws_lb_listener.https[0].default_action[0].type == "fixed-response"
    )
    error_message = "The controller-owned rule is the only weighted route and must require the origin secret."
  }
}

run "postgres_shared_state_runs_two_tasks_without_redis" {
  command = plan

  variables {
    shared_state_backend            = "postgres"
    deployment_mode                 = "MultiNode"
    desired_count                   = 2
    max_capacity                    = 6
    autoscaling_requests_per_target = 600
    file_storage_provider           = "AwsS3"
    file_storage_aws_s3_bucket_name = "honua-test-files"
    canary_enabled                  = true
  }

  assert {
    condition     = aws_appautoscaling_target.ecs.min_capacity == 2 && aws_appautoscaling_target.ecs.max_capacity == 6 && length(aws_ecs_service.canary) == 1
    error_message = "PostgreSQL shared state must satisfy the multi-task, autoscaling and canary preconditions."
  }
  assert {
    condition     = length(aws_elasticache_replication_group.redis) == 0 && length(aws_secretsmanager_secret.redis_connection) == 0 && !strcontains(aws_ecs_task_definition.this.container_definitions, "ConnectionStrings__redis")
    error_message = "PostgreSQL shared state must not provision or reference Redis."
  }
  assert {
    condition     = one(one(aws_appautoscaling_policy.requests[0].target_tracking_scaling_policy_configuration).predefined_metric_specification).predefined_metric_type == "ALBRequestCountPerTarget" && one(aws_appautoscaling_policy.requests[0].target_tracking_scaling_policy_configuration).target_value == 600
    error_message = "Request-count target tracking must run alongside the CPU policy."
  }
}

run "redis_shared_state_still_requires_redis_for_two_tasks" {
  command = plan

  variables {
    deployment_mode                 = "MultiNode"
    desired_count                   = 2
    max_capacity                    = 2
    file_storage_provider           = "AwsS3"
    file_storage_aws_s3_bucket_name = "honua-test-files"
  }

  expect_failures = [aws_ecs_service.this]
}

run "reject_cdn_without_tls" {
  command = plan
  variables {
    domain_name         = ""
    alb_certificate_arn = ""
  }
  expect_failures = [terraform_data.static_console_validation]
}

run "reject_cdn_with_open_load_balancer_ingress" {
  command = plan
  variables {
    allow_public_ingress_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [terraform_data.static_console_validation]
}

run "reject_console_certificate_that_differs_from_cdn" {
  command = plan
  variables {
    static_console = {
      viewer_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/11111111-1111-1111-1111-111111111111"
      bundle_version         = "rc.2"
    }
  }
  expect_failures = [terraform_data.static_console_validation]
}
