# AWS Lambda (Serverless) Module

Deploys Honua Server to AWS Lambda (container image) behind an API Gateway HTTP API, with RDS PostgreSQL and optional ElastiCache Redis.

## Quick start

```hcl
module "honua" {
  source = "../../modules/aws-serverless"

  environment    = "dev"
  image          = var.honua_image_uri   # Must be an ECR image URI
  admin_password = var.honua_admin_password
  enable_postgis = true  # Required — Honua needs PostGIS + PostGIS Raster

  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI       = "true"
  }
}
```

## Prerequisites

- **ECR image**: Lambda container images must be stored in ECR. Push the Honua Lambda image (`*-lambda-aot` preferred; `*-lambda` debug fallback) to your ECR repository before applying.
- **PostGIS + PostGIS Raster**: Set `enable_postgis = true` (requires `psql` on the apply machine with network access to RDS). For controlled temporary access from CI/local runners, use `db_additional_ingress_cidrs`.
- **Migrations**: `skip_migrations` defaults to `true` for serverless. Run migrations out-of-band (e.g. via a one-off ECS task or local `psql`) before first use.

## Production example

```hcl
module "honua" {
  source = "../../modules/aws-serverless"

  environment = "prod"
  name_prefix = "honua"

  # Lambda
  image                                 = var.honua_image_uri
  lambda_memory_size                    = 2048       # MB
  lambda_timeout_seconds                = 29         # Must be < API Gateway's 30s limit
  lambda_ephemeral_storage_mb           = 1024
  lambda_reserved_concurrent_executions = 100

  # Database
  admin_password       = var.honua_admin_password
  db_instance_class    = "db.r6g.large"
  db_allocated_storage = 100
  db_multi_az          = true
  db_require_ssl       = true
  enable_postgis       = true
  skip_migrations      = true   # Run migrations out-of-band

  # Redis
  redis_enabled            = true
  redis_node_type          = "cache.r6g.large"
  redis_num_cache_clusters = 2

  # Networking
  enable_nat_gateway = true  # Required for outbound access (OIDC, external APIs)

  additional_env = {
    HONUA_OBSERVABILITY = "true"
    Public__BaseUrl     = "https://gis.example.com"
  }
}
```

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `image` | *(required)* | ECR image URI. Must implement Lambda Runtime API. |
| `lambda_memory_size` | 1024 | Lambda memory in MB (128–10240). |
| `lambda_timeout_seconds` | 30 | Keep at or below 30 (API Gateway limit). |
| `lambda_architectures` | `["arm64"]` | `arm64` by default; override to `x86_64` only when you explicitly need it. |
| `lambda_alias_name` | `live` | Stable alias used for API Gateway traffic and control-plane rollback. |
| `lambda_alias_version` | `null` | Optional published version to pin the stable alias to; defaults to the version published by the current apply. |
| `enable_postgis` | **false** | Enable PostGIS + PostGIS Raster on RDS. **Set to true.** |
| `existing_db_endpoint` | `""` | Reuse an existing PostgreSQL endpoint (must be paired with `existing_db_connection_string`). |
| `existing_db_connection_string` | `""` | Reuse an existing PostgreSQL connection string (skips RDS provisioning and PostGIS local-exec). |
| `skip_migrations` | true | Skip auto-migrations. Run them out-of-band for serverless. |
| `db_instance_class` | `db.t3.micro` | RDS instance class. |
| `db_multi_az` | false | Enable Multi-AZ failover. |
| `redis_enabled` | true | Provision ElastiCache Redis. |
| `redis_connection_string` | `""` | Reuse an existing Redis connection string instead of provisioning ElastiCache. |
| `redis_connection_cidrs` | `[]` | Trusted CIDRs for Redis egress when `redis_connection_string` points to an existing endpoint. |
| `enable_nat_gateway` | true | NAT gateways for outbound access. Required for OIDC. |
| `enable_dashboard` | false | Create a CloudWatch dashboard (Lambda duration/errors/throttles/concurrency, API Gateway, cold-start, and custom Honua metrics). |
| `enable_xray_tracing` | false | Enable Lambda X-Ray active tracing, grant least-privilege `xray:PutTraceSegments`/sampling reads, and set the app-side `Tracing__XRay__Enabled` flag. |
| `enable_lambda_insights` | false | Attach the CloudWatch Lambda Insights managed policy and add the Insights widgets (the Insights extension layer must be present in the image). |
| `honua_metrics_namespace` | `Honua/Serverless` | CloudWatch namespace the custom Honua metrics (cold-start, init duration) are published to via an ADOT/EMF collector; used by the dashboard's custom widgets. |
| `enable_pro_license` | false | Deliver a signed Pro license to the Lambda via Secrets Manager so editing/sync/streaming/geocoding work. When off the server runs Community. |
| `pro_license_content` | `""` | Signed Pro license envelope JSON (relabeled hyphen-free keyId). Stored in `<name>/license-pro` and referenced by `Licensing__LicenseContentSecretRef`. Required when `enable_pro_license`. |
| `pro_license_key_id` | `honuademo2026q2` | Hyphen-free license keyId as relabeled in the envelope; used to build the legal env var name `Licensing__TrustedKeys__<keyId>`. |
| `pro_license_trusted_public_key` | `""` | Ed25519 public key (`base64url:` prefixed) that verifies the license signature. Required when `enable_pro_license`. |
| `enable_bedrock_ai` | false | Grant the Lambda role `bedrock:InvokeModel`/`InvokeModelWithResponseStream` for the configured Claude model and route the AI studio (WorkflowGeneration) flows to Amazon Bedrock. |
| `bedrock_ai_model` | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | Bedrock model id for the AI studio flows (cross-region Claude Sonnet 4.5 inference profile). |
| `bedrock_ai_region` | `us-west-2` | Region the server invokes Bedrock in. |

See `variables.tf` for the complete list.

## Pro license (Secrets Manager delivery)

Optional, **off by default**. The signed Pro license envelope (~2KB) does not fit
Lambda's 4KB total environment-variable budget, so when `enable_pro_license = true`
the module stores the envelope in a dedicated Secrets Manager secret
(`<name_prefix>-<environment>/license-pro`), grants the Lambda role
`secretsmanager:GetSecretValue` on it, and injects:

- `Licensing__LicenseContentSecretRef = aws:secretsmanager:<secret-arn>` — the server
  resolves and validates the envelope at startup (`Honua.Aws` Secrets Manager resolver).
- `Licensing__TrustedKeys__<pro_license_key_id> = <pro_license_trusted_public_key>` — the
  Ed25519 public key that verifies the signature.

The envelope's `keyId` must be **hyphen-free** (e.g. `honuademo2026q2`) because it
becomes part of the `Licensing__TrustedKeys__<keyId>` env var name; the license
signature is over the payload only, so relabeling the envelope keyId is safe as long as
the trusted key still matches. If the secret is unreachable the server degrades to
Community rather than failing to start. Cost is effectively `$0` (one small secret;
negligible reads at cold start).

```hcl
module "honua" {
  source = "../../modules/aws-serverless"
  # ...
  enable_pro_license             = true
  pro_license_content            = file("license-pro.json") # relabeled hyphen-free keyId
  pro_license_key_id             = "honuademo2026q2"
  pro_license_trusted_public_key = "base64url:Y2XgDBncW5w6n7L3YG-T6HxX51DGybWazt0_gubk30k"
}
```

## AI studio on Amazon Bedrock

Optional, **off by default**. When `enable_bedrock_ai = true`, the module grants
the Lambda execution role a least-privilege `bedrock:InvokeModel` /
`bedrock:InvokeModelWithResponseStream` policy scoped to the single Claude model
the server's `WorkflowGeneration` uses, and injects the `WorkflowGeneration__*`
env so the AI console's workflow / dashboard / report generation route to Bedrock
(see honua-server#1737). The server authenticates via the AWS credential chain
(the Lambda execution role) — without this grant the AI console gets
`AccessDenied`.

The default model is the **cross-region inference profile**
`us.anthropic.claude-sonnet-4-5-20250929-v1:0`. Invoking through an inference
profile requires both the **inference-profile ARN** (in `bedrock_ai_region`) and
the underlying **foundation-model ARNs** in every member region the `us.` profile
routes to (`us-east-1`/`us-east-2`/`us-west-2`), so the grant covers all four:

```
arn:aws:bedrock:us-west-2:<account>:inference-profile/us.anthropic.claude-sonnet-4-5-20250929-v1:0
arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0
arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0
arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0
```

## Serverless observability

Three opt-in toggles add observability for the demo Lambda, all default off:

- **`enable_dashboard`** creates `aws_cloudwatch_dashboard.serverless` with Lambda
  duration (avg/p90/max), errors/throttles/invocations, concurrency, API Gateway
  request/latency, plus cold-start and Lambda Insights rows when their sources are
  wired. Outputs `dashboard_name` and `dashboard_url`.
- **`enable_xray_tracing`** turns on Lambda **Active** tracing, attaches a
  least-privilege X-Ray policy (`xray:PutTraceSegments`, `PutTelemetryRecords`,
  and the `GetSampling*` reads), and injects `Tracing__XRay__Enabled=true` so the
  Honua app emits X-Ray-compatible trace IDs. Spans still export through the
  existing OTLP path to an ADOT/X-Ray collector, producing a request → PostGIS
  query → render trace in the X-Ray service map.
- **`enable_lambda_insights`** attaches the `CloudWatchLambdaInsightsExecutionRolePolicy`
  managed policy and the Insights dashboard widgets.

The custom Honua cold-start metrics (`honua.lambda.cold_start`,
`honua.lambda.init_duration_ms`) are emitted by the app through the shared meter;
they surface on the dashboard when an ADOT/EMF collector publishes them to
`honua_metrics_namespace`.

## Alias semantics

The module publishes immutable Lambda versions and keeps API Gateway bound to a stable alias. By default the alias follows the version published by the current apply. Set `lambda_alias_version` when you need to pin or move the alias intentionally, for example when an external control plane is promoting or rolling back a published version.

The module does not invent canary or previous-version state. It exposes the stable alias revision and the current published revision so a control-plane backend can observe the current state, capture the prior stable version, and move the alias honestly.

The deployed Honua app also self-registers its `AwsLambda` deploy target through environment-based `ControlPlane__...` settings, so the admin API can plan and observe Lambda rollouts without a separate sidecar config file.

If you want staged Lambda rollout instead of direct alias cutover, add a deploy-target parameter such as `lambda.canary_weight_percentage=10` and a valid `telemetry.connection` in the Honua control-plane configuration. The Lambda backend only promotes or rolls back the alias after telemetry settles.

## GP on AWS Batch (Fargate Spot)

Optional, **off by default**. When `enable_gp_batch = true`, the module provisions an AWS Batch backend so Honua's geoprocessing/import jobs run on Fargate Spot instead of inline in the Lambda. The Honua server's `ExecutionJobReconciler` submits and observes jobs through the built-in `AwsBatchComputeBackend` (no extra server config — the module surfaces everything via environment variables).

```hcl
module "honua" {
  source = "../../modules/aws-serverless"

  # ... existing serverless inputs ...

  enable_gp_batch = true
  gp_batch_image  = var.gp_image_uri   # ECR image for the GP worker; defaults to `image` when empty

  # Optional sizing (defaults shown). vCPU/memory must be a valid Fargate pairing.
  gp_batch_vcpus            = 1
  gp_batch_memory_mib       = 2048
  gp_batch_cpu_architecture = "X86_64"  # or ARM64 (Graviton Spot is cheaper)
  gp_batch_max_vcpus        = 16         # caps concurrency/cost; scales to zero between jobs

  # Optional: let GP jobs read/write the FileStorage data bucket.
  gp_batch_data_bucket_arn = aws_s3_bucket.data.arn
}
```

What it creates:

- A **Fargate Spot** Batch compute environment (`MANAGED`, scale-to-zero — no `min_vcpus`/`desired_vcpus`, so nothing stays warm), a **job queue**, and a **job definition** for the GP container.
- IAM: the Lambda execution role gets scoped `batch:SubmitJob` / `batch:TerminateJob` / `batch:CancelJob` on the queue + job-definition (revision wildcard), plus account-wide `batch:DescribeJobs` / `batch:ListJobs` (these do not support resource scoping). The Batch execution role gets ECR pull + CloudWatch Logs; the job role gets the same DB-secret access the Lambda has (and optional S3).
- A `ControlPlane:ExecutionWorkloads` entry injected into the Lambda env (`Backend=honua-aws-batch`, `TargetKind=AwsBatch`, `Kind=Geoprocessing`) carrying the `batch.job_queue_arn`, `batch.job_definition_arn`, `batch.region`, `batch.vcpus`, and `batch.memory_mib` parameters the backend reads at submit time.

**Cost posture** (budget-tight demo): Fargate Spot is ~70% cheaper than on-demand Fargate; the compute environment scales to zero so you pay only for the seconds a job's container runs (no idle/warm cost). At the 1 vCPU / 2 GB default, a job costs roughly **$0.012/hour** (us-east-1 Fargate Spot ~$0.0096/vCPU-hr + ~$0.00105/GB-hr) — about **$0.012 for a one-hour job, ~$0.003 for a 15-minute job**. Spot interruptions cause Batch to retry per `gp_batch_retry_attempts`.

Outputs: `gp_batch_job_queue_arn`, `gp_batch_job_definition_arn`, `gp_batch_compute_environment_arn`, `gp_batch_job_role_arn`, `gp_batch_workload_id`, `gp_batch_control_plane_backend_name` (all `null` when disabled).

## Constraints

- **API Gateway timeout**: HTTP API has a 30-second max integration timeout. Keep `lambda_timeout_seconds` in sync.
- **Cold starts**: Use an AOT Lambda image (`vX.Y.Z-lambda-aot`) for faster cold starts. Consider provisioned concurrency for latency-sensitive workloads.
- **Concurrent migrations**: Multiple Lambda invocations may attempt migrations simultaneously. Always set `skip_migrations = true` in production.

## Outputs

See `outputs.tf` for the API endpoint URL, RDS connection string, and secrets. The module also emits Honua control-plane handoff metadata:

- `environment`
- `aws_region`
- `lambda_function_name`
- `lambda_function_arn`
- `lambda_function_version`
- `lambda_alias_name`
- `lambda_alias_arn`
- `lambda_alias_invoke_arn`
- `lambda_alias_function_version`
- `control_plane_target_kind = "AwsLambda"`
- `control_plane_backend_name = "honua-gitops-aws-lambda"`
- `control_plane_target_id`
- `control_plane_target_name` and `control_plane_target_resource_id`
- `control_plane_current_revision`
- `control_plane_desired_revision`
- `control_plane_telemetry_policy = "honua-http"`
