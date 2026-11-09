# Lane build host

One Ubuntu 24.04 build host for agent lanes whose local disk cannot sustain
.NET server builds. A Spot-only Auto Scaling group has minimum zero, maximum one,
and initial desired capacity one. It offers c6i.4xlarge, c7i.4xlarge, m6i.4xlarge,
m7i.4xlarge, c6a.4xlarge, m6a.4xlarge and c5.4xlarge across one public subnet per
available regional availability zone. All options are amd64 with 16 vCPUs and at
least 30 GiB RAM. The `price-capacity-optimized` strategy selects a pool by price
and available capacity; there is no On-Demand fallback or capacity rebalance surge.

Choose `region` by current Spot prices before deployment and set it explicitly.
The region default is an example, not the expected deployment. The backend region
is configured separately in `backend.tf`. The type list replaces `instance_type`.

Cost controls:

- **Idle stop:** the installed timer checks every five minutes and scales the group
  to zero after `idle_stop_minutes` (default 30) without observed remote job markers
  or running .NET/Docker builds, provided no SSH session is younger than that
  interval. Failed activity inspection leaves capacity unchanged. The instance
  role can only set desired capacity on this group. Scaling to zero terminates the
  instance; simply shutting down EC2 would cause an immediate replacement.
- **Nightly stop (off by default):** `nightly_stop_enabled = true` scales the group
  to zero unconditionally at 03:00 America/Los_Angeles, including during builds.
- **Cost alerts:** an AWS Budget on EC2 compute cost emails `budget_alert_email` at
  80% of `monthly_budget_usd` (default 75) actual and 100% forecast. Budget data lags
  several hours; these alerts do not stop instances.

Interrupted instances are replaced while desired capacity is one. Each new host
gets a fresh encrypted gp3 root disk, so NuGet/npm/container caches must warm up.
Idle termination deletes that disk. At capacity zero, no build instance or root
disk remains billed. Terraform ignores subsequent desired-capacity changes, so
an apply does not wake an idle group. The former CPU-only stop alarm and
`idle_cpu_percent` input are removed; build activity governs the idle decision.

## Wake and discover from remote build tooling

Use the output `autoscaling_group_name` to request capacity. Replace the fixed EC2
instance ID in the shim with the output `instance_lookup_filters` (shown below).
Run these commands only from authorized operator tooling, in the selected region:

```bash
aws autoscaling set-desired-capacity --region "$BUILD_REGION" \
  --auto-scaling-group-name honua-lane-build-host --desired-capacity 1
aws ec2 describe-instances --region "$BUILD_REGION" \
  --filters Name=tag:aws:autoscaling:groupName,Values=honua-lane-build-host \
            Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[InstanceId,PublicDnsName]' --output text
```

Poll discovery until exactly one running host appears, then wait for SSH and
`cloud-init status --wait` to succeed before dispatching builds. Refresh discovery
on interruption; do not restart a terminated instance ID. Setting desired capacity
zero stops the fleet. Stopping or terminating a single EC2 instance while desired
capacity is one requests a replacement. The shim operator needs describe-instances
and set-desired-capacity permissions; the host role is scoped to its own group.

Only SSH from `allowed_ssh_cidrs` is allowed inbound. IMDSv2 is required. Docker
group membership grants root-equivalent access, including the idle-stop role.

Copy `backend.tf.example` to `backend.tf`, replace the bucket placeholder and
initialise. After the first apply, set this root to `applied=true` in
`bootstrap/drift-roots.json`. Migrating the former single-instance root destroys
that instance and its disk and replaces the old subnet with regional subnets.
Coordinate downtime and shim discovery changes with the host owner before apply.
Launch-template changes take effect on the next replacement; to roll out user
data deliberately, scale to zero, wait for termination, then scale to one after
active jobs drain. Terraform does not start a rolling refresh during builds.
