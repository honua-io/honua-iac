# aws-demo — Phase A: demo.honua.io

Terraform root config that deploys the **Phase A** hosted demo environment for
[demo.honua.io](https://demo.honua.io) using the `aws-serverless` module
(Lambda container + API Gateway HTTP API + RDS PostgreSQL).

## Why serverless for the demo

- **Scales to zero between visitors** — no idle Fargate task cost; Lambda billing
  is request-duration based.
- **Demonstrates the story** — the demo itself runs on Honua's serverless
  deployment path, so visitors can see the same architecture they'd deploy.
- **Cold starts are acceptable** — the AOT Lambda image (`vX.Y.Z-lambda-aot`)
  compiles to native code and typically cold-starts in 200–400 ms, which is
  imperceptible for a read-mostly API demo.
- **Lower operational overhead** — no ECS cluster, no ALB, no NAT gateway
  data-transfer bill for an always-on task.

## Scope

**Phase A** — a single shared, read-mostly demo instance backed by curated
public datasets. Anyone can browse the API and STAC catalog without an account.

**Phase B** (future work, not in this config) — self-service sandbox tenants on
`*.demo.honua.io`. That is a separate project and is **not** the same as
honua-server issue #346 (schema-per-tenant Enterprise multi-tenancy), which is
a data-isolation feature for production deployments.

## What this provisions

| Resource | Sizing / configuration |
|---|---|
| Lambda function | `x86_64`, 1024 MiB RAM, no provisioned concurrency (arm64 blocked on cross-build, see main.tf) |
| Lambda image | `*-lambda-aot` tag (AOT build); cold starts ~200–400 ms |
| RDS PostgreSQL | `db.t4g.micro`, version 15, 20 GB gp3, PostGIS + PostGIS Raster enabled |
| ElastiCache | **Disabled** (`redis_enabled = false`); single Lambda, no distributed cache needed |
| API Gateway | HTTP API (`protocol_type = "HTTP"`) with `$default` stage |
| ACM certificate | Auto-provisioned and DNS-validated for `demo.honua.io` |
| Route53 A record | `demo.honua.io` → API Gateway regional domain (alias) |
| API Gateway custom domain | `demo.honua.io`, TLS 1.2, regional endpoint |
| VPC | New VPC, **no NAT gateway** — VPC endpoints instead (see below) |
| VPC endpoints | Secrets Manager interface endpoint (single-AZ) + free S3 gateway endpoint |
| PostGIS bootstrap | One-shot in-VPC Lambda enables `postgis` + `postgis_raster` during apply |
| CloudWatch Logs | 90-day retention for Lambda and API Gateway |
| Secrets Manager | DB connection string, admin password, master key |

### No NAT gateway — VPC endpoints instead

A NAT gateway costs ~$33/mo before data charges, and the public demo has no
OIDC and no outbound integrations, so the Lambda needs **no general internet
egress**. What it does need at runtime is Secrets Manager (the
`aws:secretsmanager:` environment references are resolved on cold start), so
the config provisions:

- **Secrets Manager interface endpoint** (`vpc-endpoints.tf`) — single-AZ on
  purpose (~$7.30/mo for one ENI); cross-AZ hops from the other private
  subnets are fine at demo traffic levels.
- **S3 gateway endpoint** — free, attached to the private route tables, ready
  for future COG (Cloud-Optimized GeoTIFF) serving from S3.

If the demo ever needs general egress again (e.g. OIDC against an external
IdP), set `enable_nat_gateway = true` in `main.tf`.

### Database bootstrap and migrations

The RDS instance is in private subnets with no NAT/VPN, so nothing outside
the VPC can reach it — including the module's `enable_postgis` local-exec
(psql) path, which this config disables. Instead:

1. **PostGIS** — a one-shot Python Lambda inside the VPC
   (`postgis-bootstrap.tf`) enables `postgis` + `postgis_raster` as the RDS
   master user during `terraform apply`. Requires python3 + pip on the apply
   host (the pure-Python `pg8000` driver is vendored into the zip at apply
   time).
2. **Schema migrations** — the module call sets `skip_migrations = false`, so
   Honua runs its own DbUp migrations on startup (first invoke). After the
   first successful boot this can be flipped back to `true` (the serverless
   default) so cold starts skip the migration journal check. The module call
   also raises `lambda_timeout_seconds` to 60 so a slow first-boot migration
   run can finish even though API Gateway stops waiting at 30 s.

### Rate limiting (no WAF)

API Gateway HTTP API does **not** support WAFv2 association (WAF v2 attaches to
REST APIs / ALBs / CloudFront only). Rate-limiting is handled at the API Gateway
stage level via throttle settings:

| Limit | Default | Variable |
|---|---|---|
| Burst (concurrent requests) | 200 | `api_throttle_burst_limit` |
| Steady-state (req/s) | 50 | `api_throttle_rate_limit` |

These defaults are conservative for a public demo. Adjust in `terraform.tfvars`
if you need higher throughput.

If WAF-level rate-limiting becomes a hard requirement in future, the migration
path is to switch from HTTP API to a REST API (API Gateway v1) + ALB, or to
put CloudFront in front and attach a WAFv2 CLOUDFRONT-scoped ACL.

### Container/function environment

| Variable | Value |
|---|---|
| `HONUA_SERVE_API_DOCS` | `true` — OpenAPI docs served at `/api-docs` |
| `HONUA_SERVE_STAC_DEMO` | `true` — STAC demo catalog enabled |
| `MultiTenancy__Enabled` | `true` |
| `MultiTenancy__DefaultTenantId` | `public` |
| `HostValidation__AllowedHosts__1` | `demo.honua.io` |

## Lambda → RDS connection management

The module connects Lambda **directly to RDS** within the VPC — there is no
RDS Proxy layer. Lambda's security group allows egress on port 5432 to the VPC
CIDR, and the RDS security group allows ingress from the Lambda security group.

Each Lambda invocation opens its own database connection. For a low-traffic
demo this is fine; connections are released when the Lambda execution environment
is recycled (typically within minutes of inactivity). At higher concurrency
(hundreds of simultaneous Lambda instances), direct connections can exhaust
RDS `max_connections` for `db.t4g.small` (~170 connections). Options at that
point:

1. **Add RDS Proxy** — reduces connection count to a pool shared across all
   Lambda instances. The `aws-serverless` module does not currently provision a
   proxy; you would add it outside the module and pass the proxy endpoint as
   `existing_db_endpoint` / `existing_db_connection_string`.
2. **Scale up RDS** — larger instance class → more connections.
3. **Set `lambda_reserved_concurrent_executions`** — caps Lambda concurrency,
   bounding worst-case connection count.

For Phase A demo traffic, none of these mitigations are required.

## DNS prerequisites

> **Action required before applying.** Read this section carefully.

The `demo.honua.io` apex (`honua.io`) currently points to GitHub Pages via A/CNAME
records at the registrar. You **cannot** use the Route53-managed ACM validation
path without one of the following two options:

### Option A — Delegated subzone (recommended)

Create a Route53 hosted zone specifically for `demo.honua.io`. Add the NS
records the hosted zone returns to your registrar **as NS records for the
`demo` subdelegation**, without touching the `honua.io` apex records.

Steps:

1. In the AWS Console (or via Terraform), create a public Route53 hosted zone
   for `demo.honua.io`. Note the four NS values.
2. At your registrar, add an NS record set for `demo.honua.io` pointing to
   those four nameservers. This does not affect the apex `honua.io` records
   (GitHub Pages continues to work).
3. Pass the hosted zone ID to this config as `route53_zone_id`.
4. Run `terraform apply`. Terraform will create the ACM certificate,
   add the DNS validation CNAME inside the `demo.honua.io` zone, wait for
   validation, and then create the alias A record.

### Option B — Full migration

Migrate the entire `honua.io` zone to Route53. Create a hosted zone for
`honua.io`, recreate all existing records (including GitHub Pages CNAME/A),
and update the registrar NS records. Then set `route53_zone_id` to the
`honua.io` zone ID and use `domain_name = "demo.honua.io"`.

**Option A is strongly preferred** because it has zero impact on the
`honua.io` apex and GitHub Pages.

## Prerequisites

- AWS account with permissions matching the IAM policy in
  `infrastructure/terraform/bootstrap/aws-serverless/` (or equivalent).
- Terraform >= 1.5 (< 2.0).
- `python3` + `pip` on the machine running `terraform apply` — used to vendor
  the pure-Python `pg8000` driver into the PostGIS bootstrap Lambda zip. No
  psql and **no network path to RDS** are needed: PostGIS is enabled by the
  in-VPC bootstrap Lambda (see "Database bootstrap and migrations").
- A Route53 hosted zone for `demo.honua.io` (see DNS prerequisites above).
- **ECR repository** — Lambda container images must be in ECR. Push the
  `*-lambda-aot` image from GHCR to your ECR repository before applying.
- An S3 bucket + DynamoDB table for remote state (optional but strongly
  recommended for team use — uncomment the `backend "s3"` block in `versions.tf`).

## Apply steps

```bash
# 1. Push Lambda image to ECR (Lambda cannot pull from GHCR directly)
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin 123456789012.dkr.ecr.us-west-2.amazonaws.com

docker pull ghcr.io/honua-io/honua-server:v1.5.0-lambda-aot
docker tag ghcr.io/honua-io/honua-server:v1.5.0-lambda-aot \
  123456789012.dkr.ecr.us-west-2.amazonaws.com/honua-server:v1.5.0-lambda-aot
docker push 123456789012.dkr.ecr.us-west-2.amazonaws.com/honua-server:v1.5.0-lambda-aot

# 2. Copy and fill in tfvars
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 3. Initialise (with remote backend enabled, pass -backend-config or env vars)
terraform init

# 4. Review
terraform plan -out=demo.tfplan

# 5. Apply
terraform apply demo.tfplan
```

After apply, validate:

```bash
# Raw API Gateway endpoint (no custom domain required)
API_URL=$(terraform output -raw api_gateway_endpoint)
curl -f "$API_URL/healthz/ready"

# Custom domain (once DNS propagates)
curl -f https://demo.honua.io/healthz/ready

# Confirm PostGIS extensions (reported by the in-VPC bootstrap Lambda)
terraform output postgis_bootstrap_result
```

## Estimated monthly cost (us-west-2, June 2026)

| Component | Estimate |
|---|---|
| RDS db.t4g.micro, single-AZ | ~$12 |
| RDS storage, 20 GB gp3 | ~$2.50 |
| Secrets Manager interface endpoint (single-AZ) | ~$7.50 |
| S3 gateway endpoint | $0 (free) |
| NAT gateway | $0 (**removed** — was ~$33/mo + data) |
| Lambda (requests + duration, demo traffic) | ~$0–1 |
| API Gateway HTTP API (requests) | ~$0–1 |
| CloudWatch Logs (90-day, low volume) | ~$1 |
| Secrets Manager secrets, Route53 zone | ~$1.50 |
| **Total** | **~$23 / month** |

The RDS instance and the Secrets Manager endpoint dominate cost. Lambda + API
Gateway are effectively free at demo traffic volumes. Compare to the ECS/ALB
equivalent (~$120–160/mo) — the main savings are eliminating the always-on
Fargate task, the ALB (~$20/mo), and the NAT gateway (~$33/mo) that the
VPC endpoints replace.

## Post-deploy: seeding demo data

Demo datasets are loaded via the Honua Admin API import endpoints.

**Initial seed (manual, one-time):**

```bash
HONUA_URL=https://demo.honua.io
ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id honua-demo-demo/admin-password \
  --query SecretString --output text)

# Example: import a GeoPackage as tenant "public"
curl -X POST "$HONUA_URL/admin/datasets/import" \
  -H "Authorization: Bearer $ADMIN_PASSWORD" \
  -F "file=@/path/to/demo-data.gpkg" \
  -F "tenantId=public"
```

Exact datasets and import parameters are TBD — coordinate with the data team.

**Nightly reseed (follow-up work):**

To keep the demo fresh and wipe user-contributed data, configure a nightly
reseed via an EventBridge scheduled rule that invokes the Lambda function
directly with a custom seed payload:

1. An EventBridge scheduled rule (cron expression, e.g. `cron(0 3 * * ? *)`).
2. The rule invokes the Honua Lambda function with a seed-trigger event.
3. The function (or a separate seed Lambda) drops and recreates the `public`
   tenant schema and reimports the canonical demo datasets.

Alternatively, the seed job can be a one-off Lambda function or a local script
triggered by EventBridge → Lambda. Unlike ECS `RunTask`, there is no cluster
or task-definition ARN needed — just the Lambda function ARN and an invocation
policy.

This is a follow-up infrastructure item; the EventBridge rule is not included
in Phase A.

## Destroying the environment

```bash
terraform destroy
```

No ALB deletion protection flag to disable first — API Gateway has no equivalent
setting.
