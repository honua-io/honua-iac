# AWS Honua Support-Access Reference Stack (observe + break-glass)

A least-privilege, **key-free** reference pattern that lets a customer grant Honua
scoped, time-bounded support access to their AWS account. It provisions two
cross-account IAM roles:

| Role | Purpose | Access | Default max session |
| --- | --- | --- | --- |
| `HonuaSupportObserveRole` | Read-only diagnostics across Honua runtime targets | **read-only** | 1 hour |
| `HonuaSupportBreakGlassRole` | Explicit, per-ticket remediation | **short-lived write** (narrower than admin, capped by a permissions boundary) | 1 hour |

There are **no IAM users and no long-lived access keys**. Access is always a
short-lived STS session gated by an `ExternalId`, and (for break-glass) MFA and
ticket/operator session tags.

## Support-access model

```
Honua support account                 Customer AWS account
---------------------                 --------------------------------------
support principal  --AssumeRole-->    HonuaSupportObserveRole   (read-only)
(role ARN you trust)  +ExternalId     HonuaSupportBreakGlassRole (remediation)
                      +MFA*           capped by a permissions boundary
                      +session tags*
```

\* MFA and session tags are on by default (`require_mfa`, `require_session_tags`).

### Observe role (diagnostics)

Read-only across the Honua runtime targets: ECS/Fargate, Lambda, EKS, EC2/VPC,
RDS, ElastiCache, load balancers + WAF, CloudWatch metrics/logs/alarms, CloudTrail,
and **secrets metadata only** (`DescribeSecret`/`ListSecrets` - never
`GetSecretValue`). Every action is a `Describe`/`Get`/`List`, scoped by
`aws:RequestedRegion`. Honua performs diagnostics through this role.

### Break-glass role (remediation)

Elevated **but explicitly narrower than admin**. It inherits the observe
permissions and adds targeted operational actions: restart/redeploy ECS services,
update/invoke Lambda, adjust EKS node/cluster config, scale services, reboot (not
delete) RDS/ElastiCache, toggle security-group rules, drain/register load-balancer
targets, and manage log retention.

A **permissions boundary** (`HonuaSupportBreakGlassRole-boundary`) hard-caps the
role below admin even if its inline policy is later widened. It explicitly
**denies**:

- all `iam:*`, `organizations:*`, `account:*`, and further `sts:AssumeRole*`
  (no privilege escalation)
- `secretsmanager:GetSecretValue`/`Put`/`Update`/`Delete` and `kms:Decrypt`
  (no secret exfiltration)
- deletion of stateful stores and clusters (`rds:DeleteDB*`,
  `elasticache:Delete*`, `ecs:DeleteCluster`, `eks:DeleteCluster`,
  `lambda:DeleteFunction`)

## Required customer inputs

| Variable | Required | Description |
| --- | --- | --- |
| `support_principal_arns` | yes | Honua support principal ARN(s) you trust to assume the roles. |
| `external_id` | yes | Per-customer shared secret required on every AssumeRole (>= 16 chars). |
| `aws_region` | no (default `us-east-1`) | Region the role permissions are scoped to. |
| `observe_max_session_duration` | no (default `3600`) | Observe session ceiling, 3600-43200s. |
| `break_glass_max_session_duration` | no (default `3600`) | Break-glass ceiling, 3600-14400s. |
| `require_mfa` | no (default `true`) | Require MFA on break-glass assumption. |
| `require_session_tags` | no (default `true`) | Require `HonuaTicketId`/`HonuaOperator` session tags. |

## Usage

```bash
cd infrastructure/terraform/bootstrap/aws-support-access
cp terraform.tfvars.example terraform.tfvars   # fill in principals + external_id
terraform init
terraform apply
```

Hand the outputs to Honua support tooling. `terraform output support_access_manifest`
returns the role ARNs and session constraints in one object (the `ExternalId` is
deliberately excluded - share it out of band).

```hcl
support_access_manifest = {
  observe     = { role_arn = "arn:aws:iam::...:role/HonuaSupportObserveRole",   max_session_duration = 3600, access = "read-only" }
  break_glass = { role_arn = "arn:aws:iam::...:role/HonuaSupportBreakGlassRole", max_session_duration = 3600, access = "short-lived-remediation", requires_mfa = true }
  requires_external_id  = true
  requires_session_tags = true
  required_session_tags = ["HonuaTicketId", "HonuaOperator"]
}
```

## Operator workflow: approve -> assume -> diagnose/fix -> expire/revoke

1. **Approve.** A support ticket is opened and approved. Note the ticket ID and
   the operator identity.
2. **Assume (observe first).** Use cross-account assumption with the ExternalId
   and audit session tags:

   ```bash
   aws sts assume-role \
     --role-arn        "$OBSERVE_ROLE_ARN" \
     --role-session-name "honua-$TICKET_ID" \
     --external-id     "$HONUA_EXTERNAL_ID" \
     --duration-seconds 3600 \
     --tags Key=HonuaTicketId,Value=$TICKET_ID Key=HonuaOperator,Value=$OPERATOR
   ```

3. **Diagnose** read-only with the returned temporary credentials.
4. **Escalate only if needed.** For remediation, assume the break-glass role the
   same way (it also requires MFA by default). Sessions expire automatically at
   `break_glass_max_session_duration`.

   ```bash
   aws sts assume-role \
     --role-arn        "$BREAK_GLASS_ROLE_ARN" \
     --role-session-name "honua-fix-$TICKET_ID" \
     --external-id     "$HONUA_EXTERNAL_ID" \
     --serial-number   "$MFA_DEVICE_ARN" --token-code "$MFA_CODE" \
     --duration-seconds 3600 \
     --tags Key=HonuaTicketId,Value=$TICKET_ID Key=HonuaOperator,Value=$OPERATOR
   ```

5. **Expire.** Do nothing - STS sessions expire on their own. Every action is
   attributable in CloudTrail via the `HonuaTicketId`/`HonuaOperator` session
   tags and the `honua-<ticket>` session name.

### Auditing

Filter CloudTrail by `requestParameters.roleArn` (the role ARN) or by the
`HonuaTicketId` session tag to review exactly what was done under a ticket.

## Revocation and post-incident cleanup

- **Immediate kill switch (no destroy):** rotate the `ExternalId` - set a new
  value and `terraform apply`. Every in-flight and future assume-role call fails
  until Honua receives the new value.
- **Cut a specific principal:** remove its ARN from `support_principal_arns` and
  `terraform apply`.
- **Temporarily disable a role:** narrow its trust by emptying the relevant
  principal list (observe vs break-glass are independent), or `terraform destroy`
  the whole stack to remove all support access.
- **Post-incident:** confirm no break-glass session is active (sessions are <= 1h
  by default and cannot be extended), review the ticket's CloudTrail events, and
  rotate the `ExternalId` if it may have been exposed.

## Notes

- Checkov runs against `modules/` and `examples/`, not `bootstrap/`. These roles
  are intentionally read/operational rather than provisioning identities, so they
  are far narrower than the deployment bootstrap users.
- All permissions are region-scoped via `aws:RequestedRegion`; set `aws_region`
  to match where your Honua stack runs.
- This is a least-privilege **starting point**. Remove services you do not run
  (e.g. drop the EKS statements for an ECS-only deployment) to tighten further.
