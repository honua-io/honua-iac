# Customer-owned Fargate deployment candidate

This preset reuses `modules/aws-ecs`. It is a release-certification candidate;
static validation does not establish live AWS certification. The customer owns
and operates the AWS account. Support does not require account credentials,
IAM access, or an inbound support connection. Marketplace listing work is separate.

The existing module already provides new or existing VPC selection, private
Fargate tasks, encrypted RDS PostgreSQL, backups, encrypted authenticated
ElastiCache, Secrets Manager, CloudWatch logs, HTTPS ALB and guarded autoscaling.
This preset adds private-network PostGIS initialization and a static Console.

Use `bootstrap/aws-exec-identity` with the regenerated ECS manifest from this
revision. It includes CloudFront distribution, origin access control and function
lifecycle actions in a global statement without a regional condition. The older
`bootstrap/aws-ecs` identity lacks these permissions and is unsupported for this
preset. The account owner provisions the deployment identity before a live plan;
static policy tests do not establish that AWS will authorize every deployment call.

## Inputs and topology

Copy `terraform.tfvars.example` to the ignored `terraform.tfvars`. Configure the
customer's encrypted remote state as described in `backend.tf.example` and
[operator state](../../../../docs/operator-state.md). State and saved plans contain
secret values; do not send either to support or commit them.

Use `presets/rc2.tfvars.example` as the last non-secret overlay. Supply these
customer inputs in `terraform.tfvars`:

- `honua_image`: verified default AOT PostGIS-only Honua Server image **digest**.
  Resolve the desired release tag to its signed release digest; the module rejects
  mutable tags. Retain both release version and digest in deployment evidence.
- `postgis_bootstrap_image`: verified digest of a PostgreSQL client image containing
  `psql`, compatible with the task architecture. The release gate must verify this
  dependency too. Illustrative digests in examples are never deployable pins.
- `domain_name`, the regional `alb_certificate_arn`, and `static_console` with
  `viewer_certificate_arn` (ACM **us-east-1**, covering the same domain) and
  `bundle_version` (verified Console release version). Both certificates must be
  issued before deployment. Set `route53_zone_id` for managed DNS or create an
  external alias/CNAME to the output distribution domain after bundle validation.
- Strong admin credentials and an independent connection-encryption master key
  (null generates one only for a new installation); customer-owned operation-key
  ring certificate and audit-chain key Secrets Manager references, as explained
  in `terraform.tfvars.example`. Retain keys across upgrades and replacements.
- For an existing VPC, provide its ID/CIDR and at least two public and private
  subnets. Public subnets need internet routing for ALB; private subnets need
  outbound NAT or equivalent endpoints for image pulls, logging and secrets.
  Otherwise the module creates the VPC with a single NAT gateway.

CloudFront serves the single HTTPS domain. `/console` redirects to `/console/`;
`/console/*` reads a versioned private S3 origin through origin access control.
Extensionless Console routes resolve to `/console/index.html`; missing assets
remain errors. Other paths forward all methods, cookies, headers and query
parameters to ALB without response caching. Origin TLS uses the viewer Host
header and matching regional certificate. ALB accepts CloudFront's managed prefix
list and a private origin header; other requests receive 403. Port 80 is closed.
The prefix list consumes 55 security-group rules; ensure the account quota permits it.
ALB preserves CloudFront’s X-Forwarded-For header, whose rightmost entry is the
viewer IP appended by CloudFront; the server consumes that one trusted hop. This
requires the prefix-list and private-header origin restrictions to stay enabled.
The API origin response timeout is 60 seconds. Use asynchronous jobs for longer work.
See [AWS header processing](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/x-forwarded-headers.html).

The `postgis` task container connects privately to RDS over TLS, serializes
`CREATE EXTENSION IF NOT EXISTS postgis` and `postgis_raster` using an advisory
lock, then exits. Honua waits for SUCCESS before startup migrations run.
Database credentials are injected from Secrets Manager, never embedded in the
Console. The bootstrap client currently uses `sslmode=require`: traffic is encrypted but
the RDS certificate identity is **not verified**. This is an explicit preview
limitation for the account owner to assess before deployment; do not treat it as
full TLS authentication. A verified client image with the RDS CA and `verify-full`
is required to remove this limitation. The database master user currently initializes extensions and runs Honua;
separating a restricted runtime database role remains an operator hardening step.

RDS is private, encrypted, 20 GiB initially, PostgreSQL 15, `db.t3.micro`, with
production backups retained seven days. Redis OSS 7 uses `cache.t4g.micro`,
private ECS-only ingress, encryption at rest/in transit and an AUTH token in a
Secrets Manager connection secret. One Fargate task uses 0.5 vCPU/1 GiB.
Shared uploads use a private versioned S3 bucket even at one task. Scale with
`deployment_mode = "MultiNode"`, desired count 1 and max capacity N; the module
requires both Redis and shared S3 before allowing more than one replica.

## Console publication

Use the verified static WASM bundle, built with base path `/console/`. Before
upload, set its public `appsettings.json` to `apiBaseUrl: "/"` and
`auth.mode: "builtin"` (JSON nesting according to the bundle schema). Never
include admin keys, connection strings, signing keys or cloud credentials.
Optional OIDC requires the server and provider's documented callback setup.
Studio publish remains dependent on the matching server release's publish support;
verify that separately in release acceptance.

The `static_console` output gives bucket, versioned bundle prefix, distribution
ID and URL. A customer operator uploads the **contents** of the published bundle
to `<bundle_version>/console/` in that bucket, including `index.html`, runtime
configuration, WASM/framework files and compressed assets with their correct
Content-Type/Content-Encoding metadata. This is a private bucket, never a website
endpoint. The edge currently disables caching for both origins to avoid stale
runtime configuration and mixed bundle versions. No invalidation is necessary.

On a first deployment publish the bundle and validate the distribution before
sending customer traffic or enabling external DNS. A managed Route53 alias is
created during apply; disable `domain_alias_record_enabled` during staging if
an existing hostname already serves traffic. Verify `/console/`, a nested SPA
route, a missing `.js` asset (must not return HTML), authenticated API calls,
`/healthz/live`, `/healthz/ready`, and direct ALB denial. Test on the exact
release images and bundle; record browser and API receipts without secrets.

Enabling this topology on an existing ALB-only stack is not an in-place,
zero-downtime cutover: the ALB restrictions change while CloudFront deploys. Use a
parallel stack and a planned DNS cutover after validation, retaining the old stack
for rollback. The managed DNS resource keeps its address when switching targets,
but that does not make the application cutover atomic.

## Updates and rollback

Record the current commit, tfvars without secret values, image digest, Console
bundle version, database backup identifier and deployment receipt. Read release
migration compatibility notes first. Take a recoverable database backup before
an upgrade. Upload and verify the next Console prefix **before** switching
`static_console.bundle_version`; retain prior prefixes for rollback.

Change `honua_image` to the verified digest for the requested version and update
`bundle_version`. Review a saved Terraform plan before applying it. ECS registers
a new task revision; private PostGIS initialization runs first and Honua startup
runs schema migrations before readiness. The deployment circuit breaker rolls
back unhealthy service revisions. This does **not** undo schema migrations.

For operator-controlled migrations, the existing `migration_task` mode can run a
one-shot migrator in the same private network, with the same PostGIS dependency,
before the service update; use its documented migration-safety procedure. Do not
skip migration gates or run a second independent migration mechanism.

For compatible schemas, restore the previous image digest and Console version,
review and apply a new plan, and verify readiness and browser operation. For an
incompatible migration, stop writes, restore the pre-upgrade RDS backup into a
replacement database, review connection-secret and endpoint changes, then deploy
the matching previous release. Never assume an ECS rollback reverses the database.
Keep encryption/audit/key-ring secrets stable; restoring a snapshot does not
restore lost external key material.

## Support bundle without account access

The customer collects a redacted bundle: release versions and immutable digests,
IaC commit/preset, timestamp/timezone, reproduction steps, request/correlation IDs,
HTTP status and redacted body from `/healthz/live` and `/healthz/ready`, relevant
ECS service events/task stopped reasons, ALB target health, and a short log window
covering the failure. Include configuration **names and non-secret settings** and
resource sizes, not secret values, state, saved plans, raw environment dumps,
customer datasets, cookies or bearer tokens. Review every file before sending.

CloudWatch log groups follow `/honua/<name-prefix>-<environment>`; task streams use
the `honua` prefix with container name/task ID (including `postgis`). Confirm the
exact group from the task definition's `awslogs-group`. Include migration and
bootstrap errors when startup fails. RDS automated backups and CloudWatch logs
remain in the customer's account. The customer executes all diagnostic commands;
support receives only the reviewed bundle and never needs an account login.

## No-spend validation and customer-run plan

Static validation uses Terraform 1.15+ for mock-provider tests (the deployment
module remains compatible with its declared Terraform floor):

```sh
terraform fmt -check -recursive infrastructure/terraform
terraform fmt -check -recursive docs/devops/examples
terraform -chdir=infrastructure/terraform/modules/aws-ecs init -backend=false
terraform -chdir=infrastructure/terraform/modules/aws-ecs validate
terraform -chdir=infrastructure/terraform/modules/aws-ecs test -filter=tests/admin_secret_version.tftest.hcl
node infrastructure/terraform/modules/aws-ecs/scripts/console-router.test.cjs
HONUA_TERRAFORM_POLICY_STRICT=true ./infrastructure/terraform/validation/scripts/shared/terraform-policy-gate.sh
```

Mock plans do not contact AWS or create resources. cfn-lint/cfn-guard apply to
CloudFormation; this reused target is Terraform, checked by Checkov and Terraform.
A saved real-account plan needs customer credentials and read API calls; it is
**not** executed by the support lane. Once authorized, the customer/main runner
initializes its protected backend, selects verified release pins and customer
inputs, and runs `terraform plan -input=false -out=<protected-plan>` with the
rc.2 overlay. Review resource addresses, network reachability, certificate
regions, quotas, encrypted backups/Redis, secret IAM, DNS cutover, replacement
and deletion actions. Treat this as the Terraform equivalent of a dry-run change
set; do not execute apply until its plan and spend are approved. Preserve the
redacted plan summary and exact source/image/bundle identity as gate evidence.

## Estimated cost and live-test teardown

Planning allowance for us-east-1, on-demand Linux x86, 730 hours/month, one task:

| Component | Approximate USD/month |
| --- | ---: |
| Fargate 0.5 vCPU / 1 GiB | 18 |
| RDS micro plus 20 GiB storage | 18–23 |
| ElastiCache micro | 12–18 |
| Single NAT gateway | 33 |
| ALB before capacity charges | 17 |
| Public IPv4 addresses (two ALB, one NAT) | 11 |
| Secrets/KMS, S3, small logs and CloudFront allowance | 8–20 |
| **Planning total** | **117–140 (about 0.16–0.20/hour)** |

This is an estimate, not a quote. Traffic, NAT processing, CloudFront requests and
transfer, ALB capacity, snapshots, retained logs and taxes are extra. Recalculate
for the actual region and workload using current [Fargate](https://aws.amazon.com/fargate/pricing/),
[RDS](https://aws.amazon.com/rds/postgresql/pricing/),
[ElastiCache](https://aws.amazon.com/elasticache/pricing/),
[VPC](https://aws.amazon.com/vpc/pricing/) and
[CloudFront](https://aws.amazon.com/cloudfront/pricing/) rates. An existing VPC
can share already paid NAT capacity. Additional Fargate replicas add compute cost;
RDS/Redis sizing and availability must be reviewed under load.

Request a time-boxed three-hour live test only after static checks pass: allow
about **$1 runtime plus retained storage/snapshot charges**, with a reviewed
account/region budget. Main obtains founder approval and runs through the IaC
runner. Verify fresh deployment, PostGIS, Redis readiness, Console login/routes,
image and Console update, compatible rollback and customer diagnostic collection.
Do not mark release-certified until those receipts pass.

Teardown: preserve customer data/required receipts first; review a destroy plan.
Explicitly disable ALB/RDS deletion protection in a reviewed update, then destroy
the disposable stack. Versioned Console and data buckets deliberately refuse
implicit deletion: the customer must export needed objects and explicitly delete
all versions/delete markers before bucket removal. Retain/export any required
RDS final snapshot; delete disposable snapshots only after approval. Check for
remaining NAT/EIP, ALB, RDS, ElastiCache, CloudFront, buckets, logs and secrets;
record every retained resource and its continuing charge. Never destroy a
production stack as a test cleanup shortcut.
