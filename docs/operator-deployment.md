# Operator Deployment Guide

This guide is the operator-facing runbook for deploying Honua with the Terraform roots in `infrastructure/terraform/examples/*`.

## Architecture

```mermaid
flowchart TD
  Operator[Platform operator] --> Root[Terraform root<br/>examples/*]
  Root --> Runtime[Runtime target<br/>ECS | ACA | Lambda | Functions | EKS | AKS]
  Root --> Secrets[Managed secret store<br/>AWS Secrets Manager | Azure Key Vault]
  Root --> Data[PostgreSQL + optional Redis]
  Root --> Edge[Ingress / endpoint<br/>ALB | ACA ingress | API Gateway | Kubernetes ingress]
  Runtime --> Honua[Honua application]
  Data --> Honua
  Secrets --> Honua
```

## Deployable Targets

| Target | Terraform root | Runtime | Edge | Secret store | Built-in data plane | Marketplace-targeted bundle |
|---|---|---|---|---|---|---|
| AWS ECS | `infrastructure/terraform/examples/aws` | ECS/Fargate | ALB | AWS Secrets Manager | RDS PostgreSQL + optional ElastiCache | Yes |
| AWS serverless | `infrastructure/terraform/examples/aws-serverless` | Lambda container + API Gateway | HTTP API | AWS Secrets Manager | RDS PostgreSQL + optional ElastiCache | No |
| Azure ACA | `infrastructure/terraform/examples/azure` | Azure Container Apps | ACA ingress | Azure Key Vault | PostgreSQL Flexible Server + optional Azure Cache for Redis | Yes |
| Azure Functions | `infrastructure/terraform/examples/azure-functions` | Linux Function App custom container | Function App HTTPS endpoint | Azure Key Vault | PostgreSQL Flexible Server + optional Azure Cache for Redis | No |
| AWS EKS | `infrastructure/terraform/examples/aws-eks` | Managed Kubernetes cluster | Bring-your-own Helm/Ingress | Kubernetes + cloud-native integrations | Cluster only; deploy Honua separately | No |
| Azure AKS | `infrastructure/terraform/examples/azure-aks` | Managed Kubernetes cluster | Bring-your-own Helm/Ingress | Kubernetes + cloud-native integrations | Cluster only; deploy Honua separately | No |

Marketplace-targeted bundles in this repo intentionally focus on turnkey container runtimes. Serverless roots remain operator-only, and cluster-only roots remain bring-your-own-deploy orchestration targets. The machine-readable bundle matrix lives in `infrastructure/terraform/marketplace/targets.json`.

## Cross-Cloud Comparison

| Concern | AWS ECS | AWS serverless | Azure ACA | Azure Functions | EKS | AKS |
|---|---|---|---|---|---|---|
| Best fit | Long-running HTTP service | Spiky or low-baseline HTTP load | Managed container app with autoscale | Event-leaning or HTTP serverless container | Managed Kubernetes with full control | Managed Kubernetes with Azure-native ops |
| Rollout model | ECS service update, optional canary | Lambda version + alias | Revision-based container rollout | Function App image update, optional slot workflow | Helm/Kubernetes rollout | Helm/Kubernetes rollout |
| Image source expectation | ECR preferred | ECR required | Public or private OCI registry | Public or private OCI registry | Cluster pull secret or cloud registry auth | Cluster pull secret or cloud registry auth |
| Secrets injection | Task/Lambda reads Secrets Manager | Lambda reads Secrets Manager | Key Vault references into ACA secrets | Key Vault references in app settings | Helm/Kubernetes secret or external secret operator | Helm/Kubernetes secret or external secret operator |
| DB migrations | Can run in task, but pin operationally | Run out-of-band | Can run in app container, but verify carefully | Run out-of-band by default | Run as job/init task outside Terraform cluster root | Run as job/init task outside Terraform cluster root |
| Cold-start sensitivity | Low | High | Medium | Highest of the six | Cluster-dependent | Cluster-dependent |
| Cheapest steady-state profile | Small ECS task count | Lambda + shared DB | Low replica ACA + shared data | Consumption/Premium plan with shared data | Small node pools, shared services | Small node pools, shared services |

## Standard Deployment Workflow

1. Pick a Terraform root from the table above.
2. Copy the matching `terraform.tfvars.example` to `terraform.tfvars`. If you use remote state, also copy `backend.tf.example` to `backend.tf`.
3. Fill the provider-neutral `install = { ... }` questionnaire first:
   - `artifact.image` for the immutable application image
   - `database.*` for compute/storage/reuse inputs
   - `network.*` for reuse and ingress/firewall inputs
   - `storage.*` for optional object storage
   Legacy provider-specific variables still work as compatibility fallbacks, but marketplace bundles should treat `install` as the primary customer-facing surface.
4. Set the remaining secrets and operator metadata:
   - admin password
   - database password or admin password
   - tags, region, and any reuse variables (`existing_*`) if you are attaching to shared infra. When reusing a database while `enable_postgis = true`, include `existing_db_admin_password` so Terraform can authenticate and manage the extensions.
5. Apply:

```bash
terraform -chdir=infrastructure/terraform/examples/<stack> init
terraform -chdir=infrastructure/terraform/examples/<stack> plan
terraform -chdir=infrastructure/terraform/examples/<stack> apply
```

6. Verify the runtime endpoint and database connectivity before handing traffic to the stack.

## Private Registry and Image Pull

### ECS and Lambda

- Use ECR whenever possible. Lambda container images must be in ECR.
- If your source registry is GHCR, Docker Hub, or ACR, mirror the approved image into ECR as part of your release pipeline.
- Rotate pull credentials by rotating the CI identity that publishes to ECR, not by hardcoding long-lived credentials into Terraform.

### ACA and Azure Functions

- Both modules now support a provider-neutral registry contract through `install.artifact.registry.*`.
- Prefer `auth_mode = "managed_identity"` with `resource_id` pointing at the target ACR.
- Use username/password only as an explicit fallback when managed identity or federation is not available.
- Treat any registry credentials as secret-manager-backed exceptions, not the default onboarding path.
- For Functions, use the same registry settings for both the production image and the optional deployment slot image unless you are intentionally splitting promotion lanes.

### AKS and EKS

- The cluster roots provision only the cluster. Honua image pull auth is configured at Helm/Kubernetes deploy time.
- Create a pull secret, then wire it into the Helm release:

```bash
kubectl create secret docker-registry honua-registry \
  --docker-server=<registry> \
  --docker-username=<user> \
  --docker-password=<password> \
  --namespace honua

helm upgrade --install honua <chart> \
  --namespace honua \
  --set image.repository=<repo> \
  --set image.tag=<tag> \
  --set imagePullSecrets[0].name=honua-registry
```

## Cost Optimization Guide

Start conservative, then scale from observed load. The biggest cost levers are node counts, database SKU, Redis tier, and whether you provision shared data stacks separately from compute.

| Target | Highest-impact levers |
|---|---|
| AWS ECS | `desired_count`, task CPU/memory, NAT gateway use, RDS class/storage, ElastiCache size |
| AWS serverless | `lambda_memory_size`, reserved concurrency, NAT gateway use, RDS class/storage, ElastiCache size |
| Azure ACA | `min_replicas`, CPU/memory, Flexible Server SKU/storage, Redis SKU, Log Analytics retention |
| Azure Functions | plan SKU (`Y1` vs `EP1+`), deployment slot usage, Flexible Server SKU/storage, Redis SKU |
| EKS | node instance type, desired/min/max node counts, managed addon scope, separate observability footprint |
| AKS | node VM size, autoscaler min/max, Standard vs Free SKU, Log Analytics workspace usage |

Recommended patterns:

- Reuse existing DB/Redis with `existing_*` variables when your platform team already operates shared data services.
- Keep Redis optional unless you have a real cache requirement.
- Avoid production NAT gateways in ephemeral validation or one-off testing unless outbound private workloads require them.
- Pin images and avoid repeated churn from moving tags.
- For Kubernetes targets, separate cluster cost from Honua application cost; cluster roots do not deploy the app for you.

## Backup and Restore Procedure

Terraform creates infrastructure; it is not the backup controller. Use provider-native backups for PostgreSQL and treat Redis as disposable cache state unless you have a business requirement to persist it.

### PostgreSQL

1. Confirm retention settings on the managed database:
   - AWS: RDS automated backups / snapshots
   - Azure: Flexible Server PITR and retention settings
2. Capture a manual backup or snapshot before risky schema changes.
3. Restore to a new endpoint rather than restoring in place.
4. Repoint the Terraform stack to the restored database by setting the appropriate reuse inputs:
   - AWS ECS/Lambda: `existing_db_endpoint`, `existing_db_connection_string`, and `existing_db_admin_password` (when `enable_postgis = true`)
   - Azure ACA/Functions: `existing_db_fqdn`, `existing_db_connection_string`, and `existing_db_admin_password` (when `enable_postgis = true`)
5. Apply Terraform so runtime secrets update cleanly.
6. Re-run readiness and a representative data query before reopening traffic.

### Snapshot telemetry

- Each module now surfaces `latest_db_snapshot_arn` (and the same value under `operations_metadata.database.backup.latest_snapshot_arn`) so automation can confirm which automated snapshot was most recently completed. Use that ARN as the restore target when creating a replacement instance or sharing the snapshot with another region.
- When you need a cross-region replica for disaster recovery, run `aws rds create-db-instance-read-replica --db-instance-identifier honua-postgres-replica --source-db-instance-identifier <db-instance-identifier> --region <secondary-region>` and then promote it via `aws rds promote-read-replica` only during planned failover. Update your Terraform inputs to point to the promoted read replica by setting `existing_db_endpoint`/`existing_db_connection_string` and `existing_db_admin_password` so Honua can continue reading from the restored data plane.

### Redis

- Prefer rebuilding cache state after failover or restore.
- If Redis data must be retained, use the managed provider backup/replication features outside this Terraform layer and document the recovery objective separately.

### Kubernetes Targets

- AKS/EKS roots do not own Honua data. Restore the external database first, then redeploy the Helm release against the restored connection string and any required pull secrets.

## Credential Rotation Procedure

Rotate one credential class at a time and re-apply Terraform so dependent secrets update together.

### Runtime secrets

1. Generate the new value.
2. Update the source secret in CI, your vault, or `terraform.tfvars`.
3. Run `terraform plan` and `terraform apply`.
4. Confirm the managed secret store now contains the new value:
   - AWS: Secrets Manager ARNs emitted by module outputs
   - Azure: Key Vault secret IDs emitted by module outputs
5. Verify readiness and admin/API access.

When rotating the database password or reusing an existing database, also update the module input `existing_db_admin_password` so Terraform can refresh the `postgresql_extension` provider credentials without leaving PostGIS in limbo. The modules also emit structured metadata under `operations_metadata.database.secret_ref` for the DB connection and `operations_metadata.secrets.admin_password`, which you can reference when automating rotation.

Redis auth token rotation works the same way: update the `redis_auth_token` input or secret, re-run `terraform plan`/`apply`, and note that the refreshed connection string is published under `operations_metadata.secrets.redis_connection` for downstream consumers.

### Registry credentials

1. Prefer rotating the pull identity or federated subject that grants registry access.
2. If ACA/Functions use fallback credentials, update `install.artifact.registry.*` or the legacy `registry_*` inputs. For AKS/EKS, rotate the Kubernetes pull secret.
3. Re-apply or redeploy the runtime.
4. Force a fresh pull by deploying a new image tag or restarting the runtime.

### Bootstrap / CI deployment identities

1. Prefer rotating the federated trust relationship or workload identity subject in the matching `infrastructure/terraform/bootstrap/*` stack or your central identity platform.
2. Only if federation is unavailable, rotate the fallback client secret or access key and update CI secrets that feed Terraform validation and deployment.
3. Run a dry plan or validation scenario before disabling the old credential.

## Troubleshooting

| Symptom | Likely cause | First checks |
|---|---|---|
| Runtime never becomes ready | DB connectivity, migrations, or secret mismatch | Endpoint health check, runtime logs, DB firewall/security group rules, secret values |
| Azure Functions image starts but app is unhealthy | Wrong Functions image shape or slot mismatch | Confirm Functions-targeted image tag, app settings, and slot image settings |
| Lambda/API Gateway times out | Cold starts or timeout too low | Check `lambda_timeout_seconds`, image size, and concurrency settings |
| ECS service deploys but ALB health checks fail | Path, port, or secret/config mismatch | ALB target health, task logs, security groups, `/healthz/ready` |
| AKS/EKS cluster is healthy but Honua is not | Helm values or image pull auth missing | `kubectl get pods`, `kubectl describe pod`, pull secret, ingress/service wiring |

## Related Docs

- `infrastructure/terraform/README.md`
- `docs/devops/terraform-validation.md`
- `infrastructure/terraform/modules/azure-functions/README.md`
