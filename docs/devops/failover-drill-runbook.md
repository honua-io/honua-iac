# Failover Drill Runbook + RTO/RPO Evidence (AWS + Azure)

This runbook validates failover behavior for the validated managed targets and
records observed recovery characteristics (RTO/RPO) against expected objectives.
It is the companion to the
[backup/restore runbook](backup-restore-runbook.md) and follows the same manual
runbook + evidence-capture conventions as
[`terraform-validation.md`](terraform-validation.md).

- Closes honua-io/honua-iac#23.
- Related: honua-io/honua-server#356 (HA + DR playbooks), honua-io/honua-server#644
  (managed Postgres certification).
- Evidence schema: [`dr-evidence-template.json`](dr-evidence-template.json).
- Evidence helper:
  `scripts/capture-dr-drill-evidence.sh` (wrapper) ->
  `infrastructure/terraform/validation/scripts/shared/capture-dr-drill-evidence.sh`.

## Definitions

- **RTO (Recovery Time Objective)** — wall-clock time from fault injection until
  the application serves traffic again (`/healthz/ready` returns `200`). Measured
  here as `rto_seconds`.
- **RPO (Recovery Point Objective)** — the data-loss window: how much committed
  data could be lost on failover. For synchronous managed HA (RDS Multi-AZ,
  Flexible Server zone-redundant HA) the expected RPO is effectively zero; for
  read-replica/geo promotion it is the replication lag at failover time.
  Measured/estimated as `rpo_seconds`.

## Scope

| Cloud | Target | Database failover | Runtime failover |
| --- | --- | --- | --- |
| AWS | `examples/aws` (`aws-ecs`) | RDS Multi-AZ forced failover | ECS task replacement across AZs |
| AWS | `examples/aws-serverless` | RDS Multi-AZ forced failover | Lambda is multi-AZ by default |
| Azure | `examples/azure` (`azure-aca`) | Flexible Server zone-redundant HA failover | Container Apps replica reschedule |
| Azure | `examples/azure-functions` | Flexible Server zone-redundant HA failover | Functions plan reschedule / slot swap |

> Prerequisite for managed DB failover: the database must be deployed in an HA
> configuration. AWS requires `db_multi_az = true` (see `modules/aws-ecs`,
> `modules/aws-data`). Azure requires zone-redundant high availability on the
> Flexible Server. If HA is not enabled, the DB failover drill is **not
> applicable** — record it as `not-evaluated` and flag remediation rather than
> forcing a non-HA reboot.

## Expected targets (defaults to grade against)

These are the default objectives used for grading; adjust per environment SLA
and record the agreed values in the evidence `targets` block.

| Target | RTO objective | RPO objective |
| --- | --- | --- |
| RDS Multi-AZ failover | <= 120 s | 0 s (synchronous standby) |
| Flexible Server zone-redundant HA failover | <= 120 s | 0 s (synchronous) |
| ECS task replacement | <= 180 s to healthy desired count | n/a (stateless) |
| Container Apps replica reschedule | <= 180 s to healthy replica | n/a (stateless) |

## Safety

- Run drills against a non-production or disposable validation environment first.
- Forced failover is disruptive: expect a brief connection reset window.
- Do not `terraform apply` against production accounts as part of the drill.
- Always confirm HA topology before triggering a forced failover; on a non-HA
  instance a forced failover degrades into a plain reboot with real downtime.

## Measurement harness

A simple readiness poller produces the RTO measurement consistently. Start it
*before* injecting the fault:

```bash
HONUA_URL="$(terraform -chdir=infrastructure/terraform/examples/aws output -raw honua_url)"

poll_ready() {
  local url="$1"; local fault_epoch="$2"
  while true; do
    if curl -fsS --max-time 5 "$url/healthz/ready" >/dev/null 2>&1; then
      echo "rto_seconds=$(( $(date -u +%s) - fault_epoch ))"
      return 0
    fi
    sleep 2
  done
}
```

## AWS failover drill

### Database (RDS Multi-AZ forced failover)

```bash
DB_ID="$(terraform -chdir=infrastructure/terraform/examples/aws output -raw db_endpoint | cut -d. -f1)"

# 1. Confirm Multi-AZ is enabled (required).
aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].MultiAZ'   # must be true

# 2. Note the current AZ for before/after evidence.
aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].AvailabilityZone'

# 3. Inject the fault and start timing.
fault_epoch=$(date -u +%s)
aws rds reboot-db-instance --db-instance-identifier "$DB_ID" --force-failover

# 4. Measure recovery (run the poller from the harness in another shell).
poll_ready "$HONUA_URL" "$fault_epoch"

# 5. Confirm the standby took over (AZ changed).
aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].AvailabilityZone'
```

RPO for Multi-AZ is `0` (synchronous standby). Record `rpo_seconds=0` and note
the synchronous-replication assumption in the evidence.

### Runtime (ECS task replacement)

```bash
CLUSTER="$(terraform -chdir=infrastructure/terraform/examples/aws output -raw ecs_cluster_name)"
SERVICE="$(terraform -chdir=infrastructure/terraform/examples/aws output -raw ecs_service_name)"

# Kill a running task; ECS reschedules to maintain desired count across AZs.
task=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --query 'taskArns[0]' --output text)
fault_epoch=$(date -u +%s)
aws ecs stop-task --cluster "$CLUSTER" --task "$task" --reason "failover drill"
poll_ready "$HONUA_URL" "$fault_epoch"
```

For `examples/aws-serverless`, Lambda + API Gateway are inherently multi-AZ; the
runtime failover check is a steady-state `/healthz/ready` confirmation during the
DB failover above rather than a separate fault injection.

## Azure failover drill

### Database (Flexible Server zone-redundant HA forced failover)

```bash
PG_NAME="$(terraform -chdir=infrastructure/terraform/examples/azure output -raw database_fqdn | cut -d. -f1)"
RG="$(terraform -chdir=infrastructure/terraform/examples/azure output -raw resource_group_name)"

# 1. Confirm zone-redundant HA is enabled (required).
az postgres flexible-server show --resource-group "$RG" --name "$PG_NAME" \
  --query '{mode:highAvailability.mode,state:highAvailability.state}'   # mode must be ZoneRedundant

# 2. Inject the fault and start timing.
fault_epoch=$(date -u +%s)
az postgres flexible-server restart --resource-group "$RG" --name "$PG_NAME" --failover Forced

# 3. Measure recovery.
poll_ready "$HONUA_URL" "$fault_epoch"
```

RPO for zone-redundant HA is `0` (synchronous). Record `rpo_seconds=0`.

### Runtime (Container Apps replica reschedule / Functions slot)

```bash
APP="$(terraform -chdir=infrastructure/terraform/examples/azure output -raw container_app_name)"
RG="$(terraform -chdir=infrastructure/terraform/examples/azure output -raw resource_group_name)"

# Force a new revision to reschedule replicas; service should stay available
# when min_replicas >= 2.
fault_epoch=$(date -u +%s)
az containerapp revision restart --name "$APP" --resource-group "$RG" \
  --revision "$(az containerapp revision list --name "$APP" --resource-group "$RG" --query '[0].name' -o tsv)"
poll_ready "$HONUA_URL" "$fault_epoch"
```

For `examples/azure-functions`, when a deployment slot is provisioned
(`HONUA_AZURE_FUNCTIONS_DEPLOYMENT_SLOT_ENABLED=true`), a slot swap is the
runtime failover/rollback mechanism; otherwise confirm steady-state readiness
during the DB failover.

## Pass/fail criteria

A failover drill **passes** when:

- The standby/replacement takes over (DB: AZ/zone changes; runtime: desired
  count returns healthy).
- `/healthz/ready` returns `200` after failover (`post_failover_ready = true`).
- `rto_seconds <= rto_target_seconds`.
- `rpo_seconds <= rpo_target_seconds`.

It is **not applicable** when the target is not deployed in an HA configuration
(record `not-evaluated` plus a remediation note).

## Evidence capture

```bash
scripts/capture-dr-drill-evidence.sh \
  --drill failover \
  --cloud aws \
  --target aws-ecs \
  --environment prod \
  --operator "$(whoami)" \
  --db-identifier "$DB_ID" \
  --failover-trigger "rds reboot --force-failover" \
  --rto-seconds 78 \
  --rpo-seconds 0 \
  --rto-target-seconds 120 \
  --rpo-target-seconds 0 \
  --post-failover-ready true \
  --notes "AZ changed us-east-1a -> us-east-1b; synchronous Multi-AZ standby" \
  --out evidence/aws-ecs-failover-$(date -u +%Y%m%d).json
```

The helper grades RTO/RPO against the targets, records per-check verdicts, sets
the overall `verdict`, and exits non-zero on `fail`. Archive each JSON with the
run; keep real endpoints/PII out of the repository.

## Common failure modes and gaps

| Symptom | Likely cause | Action |
| --- | --- | --- |
| Forced failover acts like a full reboot (long outage) | DB not in HA (`MultiAZ=false` / HA not ZoneRedundant) | enable HA before grading; record `not-evaluated` until then |
| App errors for the whole drill window | single replica/task | set `min_replicas >= 2` (ACA) / `desired_count >= 2` (ECS) |
| RTO exceeds target | cold image pull, slow migrations on reconnect | pin warm images, ensure migrations are not re-run at reconnect |
| Connection storm after failover | no client retry/pool reconnect | confirm Npgsql pooling + retry settings in the app config |
| RPO unknown for replica/geo promotion | async replication | measure replication lag at failover; record as `rpo_seconds` |

## Reliability sign-off checklist

- [ ] AWS RDS Multi-AZ forced failover: pass, RTO/RPO within target, evidence captured.
- [ ] AWS ECS task replacement: pass, RTO within target, evidence captured.
- [ ] Azure Flexible Server HA forced failover: pass, RTO/RPO within target, evidence captured.
- [ ] Azure Container Apps reschedule: pass, RTO within target, evidence captured.
- [ ] Any non-HA target flagged `not-evaluated` with a remediation follow-up.
- [ ] Observed RTO/RPO compared against the expected targets table.
