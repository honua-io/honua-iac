# aws-demo — Phase A: demo.honua.io

Terraform root config that deploys the **Phase A** hosted demo environment for
[demo.honua.io](https://demo.honua.io) using the `aws-ecs` module.

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
| ECS Fargate task | 512 CPU units / 1024 MiB RAM, ARM64 (Graviton), 1 task |
| RDS PostgreSQL | `db.t4g.small`, version 15, 20 GB, PostGIS + PostGIS Raster enabled |
| ElastiCache | **Disabled** (single task; no distributed cache needed) |
| Application Load Balancer | HTTPS with HTTP→HTTPS redirect, deletion protection, access logs |
| ACM certificate | Auto-provisioned and DNS-validated for `demo.honua.io` |
| Route53 alias record | `demo.honua.io` → ALB (alias A record) |
| WAFv2 Web ACL | Rate-limiting: 2000 req/5 min per IP on API paths; 300 req/5 min on /admin |
| VPC | New VPC with single NAT gateway (cost saving for non-prod) |
| KMS | Auto-provisioned key for logs and secrets |
| CloudWatch Logs | 90-day retention |
| Secrets Manager | DB connection string, admin password, master key |

### Container environment

| Variable | Value |
|---|---|
| `HONUA_SERVE_API_DOCS` | `true` — OpenAPI docs served at `/api-docs` |
| `HONUA_SERVE_STAC_DEMO` | `true` — STAC demo catalog enabled |
| `MultiTenancy__Enabled` | `true` |
| `MultiTenancy__DefaultTenantId` | `public` |

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
`honua.io` zone ID and `domain_name = "demo.honua.io"`.

**Option A is strongly preferred** because it has zero impact on the
`honua.io` apex and GitHub Pages.

## Prerequisites

- AWS account with permissions matching the IAM policy in
  `infrastructure/terraform/bootstrap/aws-ecs/` (or equivalent).
- Terraform >= 1.5 (< 2.0).
- `psql` available on the machine running `terraform apply` — the `enable_postgis`
  local-exec provisioner uses it to install the PostGIS and PostGIS Raster
  extensions on the RDS instance.
- Network access from the apply host to the RDS endpoint during apply. Use
  `db_additional_ingress_cidrs` to temporarily allow your CI runner or local IP.
- A Route53 hosted zone for `demo.honua.io` (see DNS prerequisites above).
- An S3 bucket + DynamoDB table for remote state (optional but strongly
  recommended for team use — uncomment the `backend "s3"` block in `versions.tf`).

## Apply steps

```bash
# 1. Copy and fill in tfvars
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 2. Initialise (with remote backend enabled, pass -backend-config or env vars)
terraform init

# 3. Review
terraform plan -out=demo.tfplan

# 4. Apply
terraform apply demo.tfplan
```

After apply, validate:

```bash
# Health check
curl -f https://demo.honua.io/healthz/ready

# Confirm PostGIS extensions
psql "$(terraform output -raw db_endpoint)" \
  -c "SELECT extname FROM pg_extension WHERE extname IN ('postgis','postgis_raster');"
```

## Estimated monthly cost (us-east-1, June 2026)

| Component | Estimate |
|---|---|
| Fargate task (512 CPU / 1024 MiB, ARM64, ~730 h) | ~$15 |
| RDS db.t4g.small, 20 GB gp3, single-AZ | ~$30 |
| Application Load Balancer (base + LCU) | ~$20 |
| WAFv2 (Web ACL + 2 rules + requests) | ~$8 |
| NAT gateway (single) + data transfer | ~$35 |
| CloudWatch Logs (90-day, low volume) | ~$5 |
| Secrets Manager, KMS, ALB access logs S3 | ~$5 |
| **Total** | **~$120–$160 / month** |

Costs vary with traffic. The largest variable is NAT gateway data transfer.

## Post-deploy: seeding demo data

Demo datasets are loaded via the Honua Admin API import endpoints.

**Initial seed (manual, one-time):**

```bash
HONUA_URL=https://demo.honua.io
ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw admin_password_secret_arn)" \
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
reseed via:

1. An EventBridge scheduled rule (cron expression, e.g. `cron(0 3 * * ? *)`).
2. The rule triggers an ECS `RunTask` API call targeting the demo cluster.
3. The task runs a seed container (or a sidecar script) that:
   - Drops and recreates the `public` tenant schema.
   - Reimports the canonical demo datasets.
4. The ECS task role needs `ecs:RunTask` and `iam:PassRole` permissions.

This is a follow-up infrastructure item; the EventBridge rule and seed task
definition are not included in Phase A.

## Destroying the environment

```bash
# Disable ALB deletion protection first (module variable)
# Then:
terraform destroy
```

The `alb_deletion_protection = true` default will block `terraform destroy`.
Set it to `false` and apply before destroying, or use the AWS Console to
disable it manually.
