# aws-demo — Phase A: demo.honua.io

Terraform root config that deploys the **Phase A** hosted demo environment for
[demo.honua.io](https://demo.honua.io) using the `aws-serverless` module
(Lambda container + API Gateway HTTP API + RDS PostgreSQL), fronted by a
CloudFront distribution that caches tile traffic at the edge (`cloudfront.tf`).

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
| CloudFront distribution | Tile caching at the edge — see "CDN layer" below |
| Lambda function | `x86_64`, 1024 MiB RAM, no provisioned concurrency (arm64 blocked on cross-build, see main.tf) |
| Lambda image | `*-lambda-aot` tag (AOT build); cold starts ~200–400 ms |
| RDS PostgreSQL | `db.t4g.micro`, version 15, 20 GB gp3, PostGIS + PostGIS Raster enabled |
| ElastiCache | **Disabled** (`redis_enabled = false`); single Lambda, no distributed cache needed |
| API Gateway | HTTP API (`protocol_type = "HTTP"`) with `$default` stage |
| ACM certificate | Auto-provisioned and DNS-validated for `demo.honua.io` |
| Route53 A/AAAA records | `demo.honua.io` → CloudFront distribution (alias; → API Gateway custom domain and no AAAA while `route_demo_dns_to_cloudfront=false`) |
| API Gateway custom domain | `demo.honua.io`, TLS 1.2, regional endpoint |
| VPC | New VPC, **no NAT gateway** — VPC endpoints instead (see below) |
| VPC endpoints | Secrets Manager interface endpoint (single-AZ) + free S3 gateway endpoint |
| PostGIS bootstrap | One-shot in-VPC Lambda enables `postgis` + `postgis_raster` during apply |
| CloudWatch Logs | 90-day retention for Lambda and API Gateway |
| Secrets Manager | DB connection string, admin password, master key |

### CDN layer — CloudFront tile caching

`cloudfront.tf` puts a CloudFront distribution in front of the API Gateway
endpoint and repoints the `demo.honua.io` A/AAAA alias at it. Path-scoped
behaviors split the traffic:

| Routes | Behavior |
|---|---|
| `/api/v1/tiles/*` (PMTiles range proxy), `/ogc/tiles/*`, `/rest/services/*/MapServer/tile/*`, `/rest/services/*/ImageServer/tile/*`, `/fonts/*`, `/terrain/*` | Cached 24 h **enforced via `min_ttl`** (range requests cached natively); edge CORS response-headers policy; viewer `Cache-Control: public, max-age=86400, stale-while-revalidate=86400` |
| Everything else (queries, OData, admin, `/healthz`) | Pass-through, no caching, all headers/query strings forwarded |

Details that matter when changing this:

- **`min_ttl = 86400` is load-bearing** (2026-06-12): honua-server stamps
  `Cache-Control: public, max-age=3600` on tile responses, and with
  `min_ttl = 0` that origin header silently capped the edge cache at **1
  hour** — every hour each tile went cache-cold again, and a county-wide pan
  fanned out into Lambda scale-out + database connection bursts (the 48 h
  metrics autopsy showed 53300 connection-slot exhaustion behind exactly this
  pattern). `min_ttl >= default_ttl` makes CloudFront keep tile bytes the
  full 24 h regardless of the origin's `max-age`. Error responses are not
  pinned: 4xx/5xx follow the error-caching TTLs (10 s for 5xx via
  `custom_error_response`).
- **Viewer caching + stale-while-revalidate**: the response-headers policy
  overrides the viewer-facing `Cache-Control` on the cached behaviors to
  `public, max-age=86400, stale-while-revalidate=86400`, so returning
  visitors render tiles from the browser cache and revalidate in the
  background instead of re-fetching the whole viewport every hour.
- **Origin Shield (us-west-2)** is enabled on the API Gateway origin: the
  regional edge caches collapse their misses onto one shield cache in the
  origin's own region, so a cache-cold tile is rendered **once**, not once
  per POP — directly shrinking the Lambda scale-out (and its database
  connection demand) behind a burst.

- **Origin** is the regional `execute-api` endpoint, *not* `demo.honua.io`
  (that record now points at CloudFront — using it as origin would loop) and
  *not* the API Gateway custom-domain target (it only serves the
  `demo.honua.io` cert, which fails CloudFront's origin TLS validation).
  The `Host` header is deliberately **not** forwarded to the origin
  (API Gateway routes by Host); `Managed-AllViewerExceptHostHeader` forwards
  the rest, including `Range` and `Origin`.
- **Edge CORS**: a response-headers policy stamps the demo's CORS headers
  (origins `https://honua.io`, `https://www.honua.io`, `http://localhost:8123`
  — mirror of `Cors__AllowedOrigins__*` in main.tf) on the cached behaviors,
  because cached responses are shared across requesting origins. This also
  masks honua-server#1627 (missing CORS headers on error responses) for the
  tile routes.
- **Viewer cert** lives in **us-east-1** (CloudFront requirement, hence the
  `aws.us_east_1` provider alias). It validates against the same Route53
  CNAME the regional cert already created — ACM emits identical validation
  records for the same domain in every region.
- **DNS swap sequencing** for a fresh distribution: apply with
  `-var=route_demo_dns_to_cloudfront=false`, validate via the
  `cloudfront_domain_name` output (tile 200 + `X-Cache: Hit from cloudfront`
  on the second hit, CORS headers present, `/healthz/live` 200 pass-through),
  then apply with the default (`true`) to repoint `demo.honua.io`.
- **HTTP/2 + HTTP/3**, compression on, `PriceClass_100` (NA + EU edges).
- Transient origin 5xx are only cached for 10 s (`custom_error_response`)
  so a Lambda cold-start hiccup doesn't pin an error tile for 5 minutes.

**Invalidation after reseeds** — tiles are cached for 24 h, so after
re-uploading PMTiles archives or reimporting datasets, flush the tile paths:

```bash
aws cloudfront create-invalidation \
  --distribution-id "$(terraform output -raw cloudfront_distribution_id)" \
  --paths "/api/v1/tiles/*" "/ogc/tiles/*" "/rest/services/*" \
          "/fonts/*" "/terrain/*"
```

(Or invalidate just the reseeded prefix, e.g.
`/api/v1/tiles/pmtiles/maui-basemap*`. The first 1,000 invalidation paths
per month are free; a wildcard counts as one path.)

**Cost**: effectively free at demo traffic — no monthly base fee; pay
per-request/per-GB only (~$0.085/GB + $0.0075–0.01 per 10k HTTPS requests in
PriceClass_100, well under a dollar a month at current volumes), and cached
tile hits *reduce* Lambda/API Gateway/RDS load.

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

If WAF-level rate-limiting becomes a hard requirement in future, the easy
path is now to attach a WAFv2 CLOUDFRONT-scoped ACL to the existing
distribution in `cloudfront.tf` (`web_acl_id`); the CDN layer also absorbs
most tile-burst traffic before it ever reaches the API Gateway throttles.

### Container/function environment

| Variable | Value |
|---|---|
| `HONUA_SERVE_API_DOCS` | `true` — OpenAPI docs served at `/api-docs` |
| `HONUA_SERVE_STAC_DEMO` | `true` — STAC demo catalog enabled |
| `MultiTenancy__Enabled` | `true` |
| `MultiTenancy__DefaultTenantId` | `public` |
| `HostValidation__AllowedHosts__1` | `demo.honua.io` |

### Known limitation: /healthz/ready requires Redis in Production

honua-server hard-requires a durable distributed feature-change event store
(Redis) whenever ASPNETCORE_ENVIRONMENT is Production. With
`redis_enabled = false` (this config), `/healthz/live` returns 200 and the
API works normally, but **`/healthz/ready` always returns 503** ("Feature-change
event storage unavailable"). Nothing probes readiness in the Lambda deployment
path, so this is cosmetic for the demo - but don't wire `/healthz/ready` into
external uptime checks until honua-server treats the event store as optional
for single-node deployments (or Redis is enabled).

## Lambda → RDS connection management

The module connects Lambda **directly to RDS** within the VPC. Lambda's
security group allows egress on port 5432 to the VPC CIDR, and the RDS
security group allows ingress from the Lambda security group.

Each Lambda execution environment runs its own Npgsql pool, so the worst-case
connection demand is a simple product that MUST stay under the instance's
slot ceiling (Postgres `max_connections` ≈ `DBInstanceClassMemory / 9531392`
on RDS — ~112 slots on db.t4g.micro, ~225 on db.t4g.small, minus
`superuser_reserved_connections` and the bootstrap/maintenance Lambda):

```
reserved_concurrent_executions × Maximum Pool Size + headroom < max_connections
```

The 48 h metrics autopsy (2026-06-12) showed what happens when this budget is
unbounded: cache-cold MVT tile bursts → Lambda scale-out → 53300 "remaining
connection slots reserved" → 33% error rate. Three levers keep it bounded,
and all three are **encoded in Terraform** so applies stop reverting
hand-edits:

1. **`lambda_reserved_concurrent_executions`** caps the number of pools.
2. **Connection-string pool tuning** (`Maximum Pool Size`, short
   `Connection Idle Lifetime` / `Connection Pruning Interval` so idle slots
   are released quickly between bursts) — built into the module's
   connection-string secret; e.g. 30 environments × pool 3 + headroom fits a
   db.t4g.micro's ~112 slots, 50 × 4 fits a db.t4g.small's ~225.
3. **Demand reduction in front of the function**: pre-baked PMTiles archives
   for every demo raster AND vector layer (tile browsing never opens a DB
   connection), 24 h pinned CloudFront TTLs, and Origin Shield (see the CDN
   section).

**RDS Proxy gotcha (2026-06-12)**: a proxy in front of RDS is the textbook
fix here, but honua-server currently cannot speak through it — the server
sends per-session settings as the Postgres `options` startup parameter
(Npgsql `Options`), which RDS Proxy rejects with `0A000: Feature not
supported: RDS Proxy currently doesn't support command-line options`, taking
**every** DB-backed route down. Do not point the connection-string secret at
an RDS Proxy endpoint until honua-server moves those settings to a
physical-connection initializer.

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
| CloudFront (requests + data out, demo traffic) | ~$0–1 (no base fee) |
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
