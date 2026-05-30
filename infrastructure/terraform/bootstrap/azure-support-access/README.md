# Azure Honua Support-Access Reference Stack (observe + break-glass)

A least-privilege reference pattern that lets a customer grant Honua scoped,
time-bounded support access to their Azure deployment. It provisions two
**custom RBAC roles** at a scope you choose (a resource group is recommended):

| Role | Purpose | Access | Activation model |
| --- | --- | --- | --- |
| `Honua Support Observe` | Read-only diagnostics across Honua runtime targets | **read-only** | standing assignment (read-only is safe) |
| `Honua Support Break-Glass` | Explicit, per-ticket remediation | **short-lived write** (narrower than Contributor) | **Entra PIM eligibility, activated per ticket** |

There are **no service principals with standing secrets** created here and
**no standing elevated access** by default. Diagnostics use a read-only
assignment; remediation is granted just-in-time via Entra Privileged Identity
Management (PIM) and expires on its own.

## Why Azure differs from AWS

AWS models time-bounding directly in IAM via short-lived STS sessions. Azure
RBAC role assignments are **standing** unless paired with **Entra PIM**, which
adds approval, activation, and automatic expiry on top of an *eligible*
assignment. So this stack splits the work cleanly:

- **Fully automated by Terraform:** both custom role *definitions* (the exact
  least-privilege permission sets) and the read-only observe *assignment*.
- **Customer-run operational step (documented, not Terraform):** making the
  break-glass principals **PIM-eligible** for the break-glass role, with an
  activation window, approval requirement, and ticket justification. Terraform
  cannot fully provision PIM eligibility/activation policy through the standard
  AzureRM provider, so it is a documented activation step below.
- **Escape hatch:** `create_break_glass_assignment = true` makes a *standing*
  break-glass assignment for tenants without PIM — you then revoke it manually
  after each incident (see Revocation).

## Support-access model

```
Honua support principal (Entra group/SP)        Customer Azure scope (resource group)
----------------------------------------        ------------------------------------------
observe principals  --standing assignment-->     Honua Support Observe   (read-only)
break-glass princ.  --PIM eligible-->            Honua Support Break-Glass (remediation)
                       activate per ticket        time-bounded, auto-expires
                       (approval + justification)
```

### Observe role (diagnostics)

Read-only across the Honua runtime targets: Container Apps, Functions/App
Service, AKS, Container Registry, VM/VMSS (for hybrid VM-based diagnostics),
PostgreSQL Flexible Server, Redis, networking, Log Analytics / metrics /
Application Insights, and **Key Vault metadata only**.

The role grants control-plane `.../read` actions plus `Microsoft.Insights/Logs/Read`
and `Microsoft.Insights/Metrics/Read` data actions. It grants **no Key Vault
secret/key/certificate DataActions**, so support can list and inspect Key Vault
and secret *metadata* but can **never read a secret value**. This is the Azure
equivalent of "secrets metadata, never `GetSecretValue`".

### Break-glass role (remediation)

Elevated **but explicitly narrower than Contributor/Owner**. It inherits the
observe reads and adds targeted operational writes:

- Container Apps: restart/activate/deactivate revisions, redeploy, start/stop.
- Functions / App Service: restart, redeploy, config write, slot swap.
- AKS: scale node pools, start/stop cluster, fetch user kubeconfig for diagnostics.
- PostgreSQL Flexible Server: restart, reload config, start/stop (**no delete**).
- Redis: force reboot, adjust firewall rules (**no delete**).
- Networking: write/delete **NSG security rules** to unblock or contain traffic.

It deliberately grants:

- **No** `Microsoft.Authorization/roleAssignments|roleDefinitions/write|delete`
  (NotActions) — it cannot grant itself or anyone else any role, so there is no
  privilege escalation.
- **No** Key Vault secret/key DataActions — it can restart and reconfigure
  workloads but never reads or writes secret *values*.
- **No** delete on stateful stores or clusters (`flexibleServers/delete`,
  `redis/delete`, `managedClusters/delete` are in NotActions).

## Inspect-only vs write/remediation, per service

| Service | Observe (inspect-only) | Break-glass (remediation) |
| --- | --- | --- |
| Container Apps (ACA) | read revisions, config, replicas | restart/activate revisions, redeploy, start/stop |
| Functions / App Service | read sites + config | restart, redeploy, config write, slot swap |
| AKS | read cluster, node pools, detectors | scale node pools, start/stop, get user kubeconfig |
| PostgreSQL Flexible Server | read server, config, databases | restart, config write, start/stop (no delete) |
| Redis | read cache + firewall | force reboot, firewall rule write (no delete) |
| Networking | read all network resources | NSG security-rule write/delete |
| Logs / Metrics | read Log Analytics, metrics, App Insights, query logs | same (kept available during remediation) |
| Key Vault | read vault + secret/key **metadata** | same — **never** secret values |

## Required customer inputs

| Variable | Required | Description |
| --- | --- | --- |
| `scope` | yes | Subscription or (recommended) resource-group scope the roles apply to. |
| `observe_principal_object_ids` | for an observe assignment | Entra object IDs that get read-only access. |
| `break_glass_principal_object_ids` | for break-glass | Entra object IDs made PIM-eligible (or, with the escape hatch, standing). |
| `principal_type` | no (default `Group`) | `Group` (recommended), `ServicePrincipal`, or `User`. |
| `create_observe_assignment` | no (default `true`) | Standing read-only assignment. |
| `create_break_glass_assignment` | no (default `false`) | Standing elevated assignment escape hatch (no PIM). |
| `name_prefix` | no (default `Honua`) | Prefix on the custom role names. |

## Usage

```bash
cd infrastructure/terraform/bootstrap/azure-support-access
cp terraform.tfvars.example terraform.tfvars   # fill in scope + principal object IDs
terraform init
terraform apply
```

Hand the outputs to Honua support tooling. `terraform output support_access_manifest`
returns the role definition IDs, scope, and activation model in one object (no
secrets are emitted).

```hcl
support_access_manifest = {
  scope       = "/subscriptions/.../resourceGroups/honua-prod"
  observe     = { role_definition_id = "...", access = "read-only",              assignment = "standing" }
  break_glass = { role_definition_id = "...", access = "short-lived-remediation", assignment = "pim-eligible", time_bounded_via = "entra-pim-activation" }
}
```

## Operator workflow: approve -> activate -> diagnose/fix -> expire/revoke

1. **Approve.** A support ticket is opened and approved. Note the ticket ID and
   operator identity.
2. **Diagnose (observe).** Observe is a standing read-only assignment, so support
   tooling can read diagnostics immediately, scoped to the customer's resource
   group. No write access is involved.
3. **Activate break-glass only if remediation is needed.** The operator activates
   their **PIM eligibility** for the `Honua Support Break-Glass` role, supplying a
   justification (the ticket ID) and accepting the configured approval. PIM grants
   the role for a bounded window:

   ```bash
   # Self-activate a PIM-eligible role assignment for the approved window.
   az role assignment list-for-scope ...   # confirm eligibility (portal: PIM -> My roles)
   # Activation is performed in the Entra PIM portal or via the PIM Graph API,
   # with ticket justification and (recommended) approver sign-off.
   ```

4. **Remediate** with the activated role. Every action is attributable to the
   activating identity and the PIM activation record (justification = ticket ID).
5. **Expire.** Do nothing — PIM deactivates automatically at the end of the
   activation window. No standing elevated access remains.

### Recommended PIM configuration for the break-glass role

Configure these in **Entra ID -> Privileged Identity Management -> Azure
resources -> (your scope) -> Roles -> Honua Support Break-Glass**:

- **Eligible** assignments only (no active/standing) for the break-glass principals.
- **Maximum activation duration:** 1-4 hours (keep short; ticket-scoped).
- **Require justification on activation** (record the ticket ID).
- **Require approval to activate** (Honua incident approver or customer approver).
- **Require Entra MFA on activation.**
- Optionally require a ticketing-system ticket number.

These PIM settings are the **time-bounding and approval** controls; Terraform
provisions the role's *permissions*, PIM provides the *when/how-long/who-approves*.

### JIT / VM-based diagnostics (hybrid scenarios)

If a support scenario needs OS-level VM access (hybrid diagnostics), pair this
stack with **Azure Just-In-Time VM access** (Microsoft Defender for Cloud): open
the required management port (e.g. 22/3389) for the activating identity for a
bounded window via JIT, perform diagnostics, and let it auto-close. The observe
role already grants the VM/VMSS `read` and `instanceView/read` needed to inspect
VM state without OS access. Standing inbound management ports should remain
closed; JIT is the time-bounded path, mirroring the break-glass model at the
network layer.

## Auditing

- **Observe / break-glass actions:** Azure Activity Log on the scope records every
  control-plane write with the caller identity and timestamp.
- **Elevation events:** the Entra PIM activation/deactivation audit log records
  who activated the break-glass role, when, the justification (ticket ID), and the
  approver — the authoritative record that elevation was ticket-scoped.

## Revocation and post-incident cleanup

- **Time-bounded by default:** PIM-activated break-glass access auto-expires;
  nothing to revoke after a normal incident.
- **Remove eligibility:** delete the PIM eligible assignment for a principal (in
  the PIM portal) to cut future activation.
- **Cut observe access:** remove an object ID from `observe_principal_object_ids`
  (or set `create_observe_assignment = false`) and `terraform apply`.
- **Standing break-glass escape hatch:** if you used
  `create_break_glass_assignment = true`, set it back to `false` and
  `terraform apply` (or remove the object ID) to revoke immediately after the
  incident — do not leave standing elevated access in place.
- **Full removal:** `terraform destroy` removes both custom roles and any
  standing assignments. PIM eligible assignments referencing the role should be
  removed first.

## Notes

- Checkov runs against `modules/` and `examples/`, not `bootstrap/`. These roles
  are read/operational, not provisioning identities, so they are far narrower
  than the deployment bootstrap service principals.
- Scope the roles to the **resource group** that holds your Honua deployment for
  the tightest blast radius. Subscription scope is supported but broader.
- This is a least-privilege **starting point**. Remove services you do not run
  (e.g. drop the AKS actions for an ACA-only deployment) to tighten further.
- Custom role definition + assignment changes can take a few minutes to
  propagate through Azure RBAC.
