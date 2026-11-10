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
is configured separately in `backend.tf`.

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
an apply does not wake an idle group. The timer is installed before network
bootstrap and uses only Python standard-library modules, so a failed package
download does not disable idle shutdown.

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

## PR Gate runners (off by default)

`gate_runner_enabled = true` adds `gate_runner_count` (default 2) ephemeral GitHub
Actions runners for the honua-server PR Gate. They are labelled
`self-hosted, linux, x64, honua-build` and registered in the organization runner
group `honua-server-gate`, which only `gate_runner_repository` can use.

- **One job per registration.** Before each job a root-only service ends every
  process of the runner account, deletes its home and temporary files, restores a
  pristine home, starts a fresh rootless Docker daemon and requests a just-in-time
  runner configuration that is valid for exactly one job. A job therefore inherits
  no files, caches, images or processes from an earlier job.
- **Isolation.** Each runner is its own account (`gate-runner-N`): no sudo, not in
  the `docker` group, no access to `/home/ubuntu` (lane checkouts and SSH keys),
  `NoNewPrivileges`, and other users' processes are hidden. Its containers run in
  its own rootless Docker, so container root maps to an unprivileged subordinate
  UID rather than host root. An `iptables` owner rule rejects instance metadata
  (169.254.0.0/16, `fd00:ec2::254`) for the account and its rootless network stack,
  so jobs cannot obtain the instance role.
- **Resources.** Each runner and its containers share one slice capped at
  `gate_runner_cpu_quota_percent` (default 600, six vCPUs) and
  `gate_runner_memory_max_gib` (default 10). Two gate jobs at the cap leave lane
  builds at least four vCPUs and 12 GiB.
- **Registration credential.** The `/honua-lane-build-host/gate-runner/github-app`
  SecureString holds `{"app_id": "...", "private_key": "..."}` for a GitHub App with
  organization **Self-hosted runners: write**. Terraform creates it with the value
  `unset` and ignores later values. Only root services on the host read it; each
  registration requests an installation token narrowed to that one permission and
  revokes it afterwards. Credentials are passed in root-only files, never in
  process arguments.
- **Wake and readiness.** Every 30 seconds the host writes its instance ID, a
  timestamp and its idle runner count to `/honua-lane-build-host/gate-runner/heartbeat`.
  The PR Gate assumes the output `gate_runner_wake_role_arn` by GitHub OIDC (only
  `pull_request` runs of the repository). That role can describe Auto Scaling
  groups, set this group's desired capacity and read the heartbeat, nothing else.
  The gate wakes the group, uses the runners if the heartbeat from the in-service
  instance is fresh and shows two idle runners within three minutes, and otherwise
  runs on GitHub-hosted runners.
- **Idle stop.** A running job (`Runner.Worker`) counts as build activity. Idle
  runners waiting for work do not, so the host still stops after
  `idle_stop_minutes` without jobs.

One-time setup before enabling:

1. Grant the GitHub App the organization permission **Self-hosted runners:
   Read and write** and approve the installation's permission request.
2. Create the runner group, limited to honua-server:

   ```bash
   repo_id=$(gh api repos/honua-io/honua-server --jq .id)
   gh api -X POST orgs/honua-io/actions/runner-groups -f name=honua-server-gate \
     -f visibility=selected -F allows_public_repositories=true \
     -F "selected_repository_ids[]=${repo_id}"
   ```

3. Apply with `gate_runner_enabled = true`, then store the App credential (the
   key never appears in arguments or output):

   ```bash
   umask 077
   jq -n --arg app_id "$APP_ID" --rawfile private_key "$KEY_PEM" \
     '{app_id: $app_id, private_key: $private_key}' > /tmp/gate-runner-app.json
   aws ssm put-parameter --region "$BUILD_REGION" --overwrite --type SecureString \
     --name /honua-lane-build-host/gate-runner/github-app \
     --value file:///tmp/gate-runner-app.json > /dev/null
   shred -u /tmp/gate-runner-app.json
   ```

4. Roll out the new launch template by scaling to zero and back to one (see above).

The runner version and checksum are pinned in `gate-runner.tf`; ephemeral runners
also self-update if GitHub requires a newer version before the pin is bumped.
