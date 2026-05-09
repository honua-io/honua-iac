# AWS ECS/Fargate Module

Provisions Honua Server on ECS/Fargate with an ALB, RDS PostgreSQL, optional ElastiCache Redis, and supporting infrastructure (VPC, secrets, logging).

## Quick start (dev)

```hcl
module "honua" {
  source = "../../modules/aws-ecs"

  environment    = "dev"
  image          = "123456789012.dkr.ecr.us-west-2.amazonaws.com/honua-server:v1.2.3-ecs-aot"
  admin_password = var.honua_admin_password
  enable_postgis = true  # Required — Honua needs PostGIS + PostGIS Raster

  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI       = "true"
  }
}
```

> **PostGIS + PostGIS Raster are required.** Set `enable_postgis = true` to enable both extensions on the RDS instance via a local-exec provisioner. This requires `psql` on the machine running `terraform apply` and network access to the RDS endpoint. If you cannot run local-exec, enable both extensions manually after apply. For controlled temporary access from CI/local runners, use `db_additional_ingress_cidrs`.
>
> If you do not set `allow_http_ingress_cidrs` or `allow_https_ingress_cidrs`, the ALB listener defaults to VPC-only ingress using the active VPC CIDR. Set explicit CIDRs before exposing the service more broadly.

## Production example

```hcl
module "honua" {
  source = "../../modules/aws-ecs"

  environment = "prod"
  name_prefix = "honua"

  # Container
  image            = "123456789012.dkr.ecr.us-west-2.amazonaws.com/honua-server:v1.2.3-ecs-aot"  # Pin to a release ECS AOT tag in ECR
  container_cpu    = 1024   # 1 vCPU
  container_memory = 2048   # 2 GB
  desired_count    = 2      # Minimum 2 for HA

  # Database
  admin_password       = var.honua_admin_password
  db_instance_class    = "db.r6g.large"    # Production-grade instance
  db_allocated_storage = 100               # GB
  db_multi_az          = true              # Failover replica
  db_require_ssl       = true
  enable_postgis       = true

  # Redis (multi-node caching)
  redis_enabled            = true
  redis_node_type          = "cache.r6g.large"
  redis_num_cache_clusters = 2

  # Networking
  vpc_cidr             = "10.0.0.0/16"
  enable_nat_gateway   = true
  assign_public_ip     = false

  # HTTPS
  alb_certificate_arn     = var.acm_certificate_arn
  alb_deletion_protection = true

  # Logging and monitoring
  log_retention_days         = 365
  enable_container_insights  = true
  alb_access_logs_enabled    = true

  # Optional ALB canary path
  canary_enabled           = true
  canary_image             = "123456789012.dkr.ecr.us-west-2.amazonaws.com/honua-server:v1.2.4-ecs-aot"
  canary_desired_count     = 1
  canary_weight_percentage = 0

  # Security
  waf_web_acl_arn = var.waf_acl_arn  # Optional WAFv2

  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI       = "true"
    HONUA_OBSERVABILITY  = "true"
    HONUA_OPENTELEMETRY  = "true"
    Public__BaseUrl      = "https://gis.example.com"
  }

  tags = {
    Project     = "honua"
    Environment = "prod"
  }
}
```

## HTTPS

Provide an ACM certificate for the HTTPS listener:

```hcl
alb_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/..."
```

HTTP-to-HTTPS redirect is enabled by default when a certificate is provided. Disable with `alb_enable_http_redirect = false`.

### ACM with Route 53 (auto-provisioned)

If you own a Route 53 zone, the module can create and validate the certificate for you:

```hcl
domain_name     = "gis.example.com"
route53_zone_id = "Z1234567890ABC"
```

When both values are set, the module also creates a Route 53 alias `A` record for `domain_name` that points at the ALB, and `service_url` uses the custom HTTPS hostname. Disable that DNS record with `domain_alias_record_enabled = false` if another DNS provider owns the public zone; in that case, create the external DNS record yourself and keep using `service_url` as the custom HTTPS endpoint.

For public API hosts, allow HTTPS from the intended client CIDRs:

```hcl
allow_https_ingress_cidrs = ["0.0.0.0/0"]
```

## ALB canary rollout

The module can provision an optional canary ECS service and ALB target group. This is intended for weighted rollouts on AWS without moving rollout logic into Honua itself.

```hcl
canary_enabled           = true
canary_image             = "ghcr.io/honua-io/honua-server:v1.2.4-aot"
canary_desired_count     = 1
canary_weight_percentage = 0
```

Recommended rollout sequence:

1. Apply with `canary_enabled = true` and `canary_weight_percentage = 0`.
2. Verify the canary directly through the ALB header route:
   `curl -H "X-Honua-Canary: always" https://<alb-url>/healthz/ready`
3. Increase `canary_weight_percentage` gradually in later applies.
4. Set `canary_weight_percentage = 0` again before tearing down the canary service.

When canary is enabled, the module also creates a header-based listener rule so operators can route requests directly to the canary target group without changing the default traffic split.

### Control-plane telemetry hints

The module does not provision Prometheus itself, but it exports recommended Honua control-plane metadata so rollback gates can be wired consistently:

- `control_plane_target_kind = "AwsEcs"`
- `control_plane_backend_name = "honua-gitops-aws-ecs"`
- `control_plane_telemetry_policy = "aws-alb-canary"` when canary is enabled, otherwise `honua-http`
- `control_plane_telemetry_prometheus_job = "honua"`
- `control_plane_telemetry_prometheus_canary_job = "honua-canary"` when canary is enabled

If your Prometheus scrape config uses different job names, override the corresponding `telemetry.prometheus.*` target parameters in Honua.

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `image` | Required | Container image. Pin to an immutable release tag or digest. AOT builds are recommended. |
| `task_cpu_architecture` | `ARM64` | Fargate CPU architecture. Honua defaults to Arm on AWS; override to `X86_64` only when required. |
| `container_cpu` | 512 | Fargate CPU units (256/512/1024/2048/4096). |
| `container_memory` | 1024 | Fargate memory in MiB. |
| `desired_count` | 1 | Number of tasks. Use 2+ for production. |
| `canary_enabled` | false | Provision a secondary ECS service and ALB target group for canary rollouts. |
| `canary_image` | `""` | Optional image override for the canary service. Reuses `image` when empty. |
| `canary_desired_count` | 1 | Number of tasks in the canary ECS service. |
| `canary_weight_percentage` | 0 | Percentage of default ALB traffic routed to the canary target group. |
| `canary_header_name` | `X-Honua-Canary` | Header name that forces ALB routing to the canary target group. |
| `canary_header_value` | `always` | Header value that forces ALB routing to the canary target group. |
| `enable_postgis` | **false** | Enable PostGIS + PostGIS Raster on RDS. **Set to true.** |
| `existing_db_endpoint` | `""` | Reuse an existing PostgreSQL endpoint (must be paired with `existing_db_connection_string`). |
| `existing_db_connection_string` | `""` | Reuse an existing PostgreSQL connection string (skips RDS provisioning and PostGIS local-exec). |
| `db_instance_class` | `db.t3.micro` | RDS instance class. Use `db.r6g.*` for production. |
| `db_multi_az` | false | Enable Multi-AZ failover. Recommended for production. |
| `db_require_ssl` | true | Append SSL requirements to the connection string. |
| `redis_enabled` | true | Provision ElastiCache Redis. |
| `redis_connection_string` | `""` | Reuse an existing Redis connection string instead of provisioning ElastiCache. |
| `redis_connection_cidrs` | `[]` | Trusted CIDRs for Redis egress when `redis_connection_string` points to an existing endpoint. |
| `redis_node_type` | `cache.t3.micro` | ElastiCache node type. |
| `alb_certificate_arn` | `""` | ACM certificate ARN. Falls back to HTTP if empty. |
| `waf_web_acl_arn` | `""` | WAFv2 Web ACL ARN for the ALB. |
| `enable_nat_gateway` | true | NAT gateways for private subnets (required for outbound). |
| `log_retention_days` | 365 | CloudWatch log retention. |
| `kms_key_arn` | `""` | Existing KMS key for logs/secrets. Creates one if empty. |

See `variables.tf` for the complete list.

## Outputs

See `outputs.tf` for ALB URL, ECS service names, canary routing headers, control-plane telemetry hints, RDS endpoint, secrets ARNs, and connection strings.

## After apply

1. Verify extensions: `psql $CONNECTION_STRING -c "SELECT PostGIS_Version(); SELECT extname FROM pg_extension WHERE extname IN ('postgis','postgis_raster');"`
2. Health check: `curl -f https://<alb-url>/healthz/ready`
3. If using OIDC, configure env vars per [Security Configuration](../../../../docs/devops/security.md)
