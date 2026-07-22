# Backup / Restore Drill Runbook (AWS + Azure)

This runbook turns "backups exist" into a tested operator workflow for the
validated managed targets. It defines a repeatable database backup/restore
drill, a post-restore smoke workflow, evidence capture, pass/fail criteria,
and common failure modes.

It is a manual runbook in the same family as
[`terraform-validation.md`](terraform-validation.md). The automated AWS/Azure
integration scripts already run an inline `verify_db_backup_restore` drill
during live validation; this runbook is the standalone operator procedure plus
the evidence contract used when validating a real deployment.

- Closes honua-io/honua-iac#22.
- Companion failover/RTO-RPO procedure:
  [`failover-drill-runbook.md`](failover-drill-runbook.md).
- Evidence schema: [`dr-evidence-template.json`](dr-evidence-template.json).
- Evidence helper:
  `scripts/capture-dr-drill-evidence.sh` (wrapper) ->
  `infrastructure/terraform/validation/scripts/shared/capture-dr-drill-evidence.sh`.

## Scope

Validated managed targets:

| Cloud | Target stack | Compute | Database |
| --- | --- | --- | --- |
| AWS | `examples/aws` (`aws-ecs`) | ECS/Fargate | RDS for PostgreSQL |
| AWS | `examples/aws-serverless` | Lambda + API Gateway | RDS for PostgreSQL |
| Azure | `examples/azure` (`azure-aca`) | Container Apps | PostgreSQL Flexible Server |
| Azure | `examples/azure-functions` | Functions | PostgreSQL Flexible Server |

Two restore paths are covered:

1. **Logical restore drill** (`pg_dump` -> fresh database -> `pg_restore`).
   Cloud-agnostic, non-destructive, and the default verification path. This is
   the path automated in the validation scripts.
2. **Managed snapshot / point-in-time restore (PITR)** into a *new* instance.
   Cloud-specific, exercises the provider's backup machinery, and is the path
   you run before a reliability sign-off.

> Safety: never restore over a production database. The logical drill restores
> into a throwaway `honua_restore_check` database; the managed-restore drill
> always provisions a *new* instance/server and is destroyed afterwards. Do not
> run `terraform apply` against production accounts as part of this drill.

## Prerequisites

- Terraform-deployed Honua stack (see [`../operator-deployment.md`](../operator-deployment.md)).
- Local PostgreSQL client tools (`psql`, `pg_dump`, `pg_restore`) matching the
  server major version, or Docker (`postgres:16-alpine`) as a fallback.
- `jq` for evidence capture.
- Cloud CLI authenticated for the managed-restore path: `aws` or `az`.
- Connectivity to the database endpoint. For private databases, run from a host
  inside the VPC/VNet (bastion, the deployment runner, or a temporary firewall
  rule that you remove afterwards).
- The database admin password (exported as `PGPASSWORD` for the drill commands).

Collect the connection coordinates from Terraform outputs:

```bash
# AWS (ECS)
terraform -chdir=infrastructure/terraform/examples/aws output -raw db_endpoint
# AWS (serverless)
terraform -chdir=infrastructure/terraform/examples/aws-serverless output -raw db_endpoint
# Azure (Container Apps)
terraform -chdir=infrastructure/terraform/examples/azure output -raw database_fqdn
# Azure (Functions)
terraform -chdir=infrastructure/terraform/examples/azure-functions output -raw db_fqdn
```

## Pass/fail criteria

A backup/restore drill **passes** only when all of the following hold:

- The backup (logical dump or managed snapshot/PITR) completes without error.
- The restored database contains at least one application base table
  (`restored_table_count > 0`).
- Both PostGIS extensions are present in the restored database
  (`postgis` and `postgis_raster`; `postgis_extension_count == 2`).
- A post-restore readiness smoke against the application succeeds
  (`/healthz/ready` returns `200`).
- Restore duration is within the agreed RTO target for the target
  (`restore_seconds <= rto_target_seconds`). Default validation target:
  900 seconds for the logical drill; record the managed-restore time separately.

The drill **fails** if any check fails. Record the result either way.

## AWS backup/restore drill

### Path A — logical restore drill (default, non-destructive)

```bash
export PGHOST="$(terraform -chdir=infrastructure/terraform/examples/aws output -raw db_endpoint)"
export PGUSER=honua
export PGPASSWORD='***'         # DB admin password
export PGSSLMODE=require

start=$(date -u +%s)

# 1. Back up the live application database.
pg_dump "host=$PGHOST port=5432 dbname=honua user=$PGUSER sslmode=require" -Fc -f /tmp/honua.dump

# 2. Restore into a throwaway database.
psql "host=$PGHOST port=5432 dbname=postgres user=$PGUSER sslmode=require" -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS honua_restore_check'
psql "host=$PGHOST port=5432 dbname=postgres user=$PGUSER sslmode=require" -v ON_ERROR_STOP=1 -c 'CREATE DATABASE honua_restore_check'
pg_restore --no-owner --no-privileges -d "host=$PGHOST port=5432 dbname=honua_restore_check user=$PGUSER sslmode=require" /tmp/honua.dump

# 3. Verify contents.
tables=$(psql "host=$PGHOST port=5432 dbname=honua_restore_check user=$PGUSER sslmode=require" -tA -c \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema IN ('public','honua') AND table_type='BASE TABLE';")
exts=$(psql "host=$PGHOST port=5432 dbname=honua_restore_check user=$PGUSER sslmode=require" -tA -c \
  "SELECT COUNT(*) FROM pg_extension WHERE extname IN ('postgis','postgis_raster');")

# 4. Clean up the throwaway database.
psql "host=$PGHOST port=5432 dbname=postgres user=$PGUSER sslmode=require" -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS honua_restore_check'

end=$(date -u +%s)
echo "restore_seconds=$((end - start)) tables=$tables postgis_extensions=$exts"
```

This mirrors `verify_db_backup_restore` in
`infrastructure/terraform/validation/scripts/aws/run-aws-terraform-integration.sh`,
which is also exercised automatically during AWS live validation.

### Path B — RDS snapshot / PITR restore (managed backup machinery)

```bash
DB_ID="$(terraform -chdir=infrastructure/terraform/examples/aws output -raw db_endpoint | cut -d. -f1)"

# Confirm automated backups are configured (retention > 0).
aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].{retention:BackupRetentionPeriod,window:PreferredBackupWindow,multiaz:MultiAZ}'

start=$(date -u +%s)

# Point-in-time restore into a NEW instance (never over the source).
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier "$DB_ID" \
  --target-db-instance-identifier "${DB_ID}-restore-drill" \
  --use-latest-restorable-time

aws rds wait db-instance-available --db-instance-identifier "${DB_ID}-restore-drill"
end=$(date -u +%s)
echo "managed_restore_seconds=$((end - start))"

# ... run the contents checks from Path A against the restored endpoint ...

# Tear down the drill instance.
aws rds delete-db-instance --db-instance-identifier "${DB_ID}-restore-drill" --skip-final-snapshot
```

Backup retention is set by the data modules
(`backup_retention_period = var.environment == "prod" ? 7 : 3` in
`modules/aws-data` and `modules/aws-ecs`). Confirm `prod` environments report
7-day retention.

## Azure backup/restore drill

### Path A — logical restore drill (default, non-destructive)

Identical to the AWS Path A, using the Azure FQDN and the
`adminuser@servername` login form Flexible Server expects:

```bash
export PGHOST="$(terraform -chdir=infrastructure/terraform/examples/azure output -raw database_fqdn)"
export PGUSER=honua          # Flexible Server uses the bare admin user with PG 14+
export PGPASSWORD='***'
export PGSSLMODE=require
# then run the same dump -> restore -> verify -> cleanup steps as AWS Path A
```

### Path B — Flexible Server geo/PITR restore

```bash
PG_NAME="$(terraform -chdir=infrastructure/terraform/examples/azure output -raw database_fqdn | cut -d. -f1)"
RG="$(terraform -chdir=infrastructure/terraform/examples/azure output -raw resource_group_name)"

# Confirm retention + geo-redundancy.
az postgres flexible-server show --resource-group "$RG" --name "$PG_NAME" \
  --query '{retention:backup.backupRetentionDays,geo:backup.geoRedundantBackup}'

start=$(date -u +%s)

# Point-in-time restore into a NEW server.
az postgres flexible-server restore \
  --resource-group "$RG" \
  --name "${PG_NAME}-restore-drill" \
  --source-server "$PG_NAME" \
  --restore-time "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"

end=$(date -u +%s)
echo "managed_restore_seconds=$((end - start))"

# ... run the contents checks against the restored server ...

# Tear down the drill server.
az postgres flexible-server delete --resource-group "$RG" --name "${PG_NAME}-restore-drill" --yes
```

`db_backup_retention_days` and `db_geo_redundant_backup_enabled` are set in
`modules/azure-data` and `modules/azure-aca`. For a reliability sign-off,
confirm geo-redundant backups are enabled in `prod`.

## Post-restore smoke workflow

After any restore path, confirm the application is healthy against the restored
data (or, for managed restore, after repointing a test compute instance at the
restored endpoint):

```bash
HONUA_URL="$(terraform -chdir=infrastructure/terraform/examples/aws output -raw honua_url)"
python3 - "$HONUA_URL" <<'PY'
import sys
from honua_sdk import HonuaClient

with HonuaClient(sys.argv[1]) as client:
    print(client.readiness())
PY
```

A successful readiness response covers process liveness plus restored database
and startup dependencies.

For a deeper smoke (admin CRUD: `create connection -> publish layer -> query`),
the live validation scripts already cover this against the deployed app; reuse
`run_admin_api_crud_smoke` semantics if you need an end-to-end content check.

## Evidence capture

Record every drill as a JSON evidence object that matches
[`dr-evidence-template.json`](dr-evidence-template.json):

```bash
scripts/capture-dr-drill-evidence.sh \
  --drill backup-restore \
  --cloud aws \
  --target aws-ecs \
  --environment prod \
  --operator "$(whoami)" \
  --db-identifier "$DB_ID" \
  --backup-method "pg_dump+pg_restore" \
  --restore-seconds 412 \
  --restored-table-count 37 \
  --postgis-extension-count 2 \
  --rto-target-seconds 900 \
  --notes "logical restore drill; managed PITR recorded separately" \
  --out evidence/aws-ecs-backup-restore-$(date -u +%Y%m%d).json
```

The helper grades the measurements against the targets, sets a `verdict`
(`pass` / `fail` / `not-evaluated`), and exits non-zero on `fail` so the drill
can gate a pipeline. Archive the JSON next to the run; do not commit real
endpoints or operator PII into the repository.

## Common failure modes

| Symptom | Likely cause | Action |
| --- | --- | --- |
| `pg_dump`/`pg_restore` version mismatch error | local client older than server | use the Docker fallback (`postgres:16-alpine`) or upgrade client tools |
| `connection timed out` to endpoint | private DB, no VPC/VNet path | run from a bastion/runner or add a temporary firewall rule and remove it after |
| `restored_table_count == 0` | dumped the wrong database, or migrations never ran | confirm app DB name is `honua` and the app has booted at least once |
| `postgis_extension_count < 2` | PostGIS not installed in restored DB | `CREATE EXTENSION postgis; CREATE EXTENSION postgis_raster;` then re-verify |
| RDS PITR fails: backups disabled | `backup_retention_period = 0` | set retention > 0 (modules default to >= 3) and re-snapshot |
| Azure restore fails: geo restore unavailable | geo-redundant backups disabled | set `db_geo_redundant_backup_enabled = true`, wait for first geo backup |
| Restore exceeds RTO target | undersized instance / large dataset | size for restore throughput, consider snapshot/PITR over logical restore |

## Reliability sign-off checklist

- [ ] AWS logical restore drill: pass, evidence captured.
- [ ] AWS managed snapshot/PITR drill into a new instance: pass, evidence captured.
- [ ] Azure logical restore drill: pass, evidence captured.
- [ ] Azure Flexible Server PITR drill into a new server: pass, evidence captured.
- [ ] Post-restore `/healthz/ready` smoke passes on each target.
- [ ] Restore timing recorded and within the RTO target for each target.
- [ ] Failure modes encountered are documented in the evidence `notes`.
