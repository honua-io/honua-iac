# Lane build host

One on-demand Ubuntu 24.04 build host for agent lanes whose local disk cannot sustain
.NET server builds. It is a persistent spot instance: when AWS reclaims capacity it stops
and keeps its disk, so NuGet, npm and container caches survive.

Cost controls, all in this root:

- **Idle stop:** a CloudWatch alarm stops the host after `idle_stop_minutes` (default 30)
  of average CPU below `idle_cpu_percent`.
- **Nightly stop (off by default):** with `nightly_stop_enabled = true`, an EventBridge
  Scheduler schedule stops it unconditionally at 03:00 America/Los_Angeles. It is off because
  lanes build overnight and a scheduled stop interrupts running builds.
- **Cost alerts:** an AWS Budget on EC2 compute cost emails `budget_alert_email` at 80% of
  `monthly_budget_usd` (default 75) actual and 100% forecast. Budgets data lags several
  hours, so alerts warn; the two stops above are what bound the bill.

A stopped host costs only its disk. Starting it again is an operational action on this
managed instance (`aws ec2 start-instances`), not a configuration change.

Only SSH from `allowed_ssh_cidrs` is allowed inbound; the host has no instance profile.
The public DNS name changes after every stop and start. Docker group membership grants
root-equivalent access on the host.

Copy `backend.tf.example` to `backend.tf`, replace the bucket placeholder and initialise.
After the first apply, set this root to `applied=true` in `bootstrap/drift-roots.json`.

The installed `honua-build-host-idle-stop.timer` checks every five minutes. The
host stops after thirty minutes without observed remote job markers or running
.NET/Docker builds, provided no SSH session is younger than thirty minutes. It
keeps its disk and starts again through the remote build tooling. Failed process
inspection leaves it running. The installation is part of user data; applying
changed user data replaces the instance, so coordinate rollout with the host owner.
