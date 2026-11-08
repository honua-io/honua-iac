# Lane build host

One on-demand Ubuntu 24.04 build host for agent lanes whose local disk cannot sustain
.NET server builds. It is a persistent spot instance: when AWS reclaims capacity it stops
and keeps its disk, so NuGet, npm and container caches survive.

Cost controls, all in this root:

- **Idle stop:** a CloudWatch alarm stops the host after `idle_stop_minutes` (default 30)
  of average CPU below `idle_cpu_percent`.
- **Nightly stop:** an EventBridge Scheduler schedule stops it unconditionally
  (default 02:00 America/Los_Angeles).
- **Monthly cap:** an AWS Budgets action stops it automatically when the cost tagged
  `Owner=lane-builds` reaches `monthly_budget_usd` (default 75) and emails
  `budget_alert_email`. The root activates the `Owner` cost allocation tag that the
  budget filters on; tagged cost appears in Budgets about a day later.

A stopped host costs only its disk. Starting it again is an operational action on this
managed instance (`aws ec2 start-instances`), not a configuration change.

Only SSH from `allowed_ssh_cidrs` is allowed inbound; the host has no instance profile.
The public DNS name changes after every stop and start. Docker group membership grants
root-equivalent access on the host.

Copy `backend.tf.example` to `backend.tf`, replace the bucket placeholder and initialise.
After the first apply, set this root to `applied=true` in `bootstrap/drift-roots.json`.
