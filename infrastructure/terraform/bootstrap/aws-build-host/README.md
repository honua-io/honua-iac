# Lane build host

One Ubuntu 24.04 build host for agent lanes whose local disk cannot sustain
.NET server builds. A Spot-only Auto Scaling group has minimum zero, maximum one,
and initial desired capacity one. It offers 64-vCPU (`*.16xlarge`) c, m and r instance types
across one public subnet per available regional availability zone, all amd64 with at
least 128 GiB RAM, on a gp3 root volume at 12,000 IOPS and 1,000 MiB/s. The `price-capacity-optimized` strategy selects a pool by price
and available capacity; there is no On-Demand fallback or capacity rebalance surge.

Choose `region` by current Spot prices before deployment and set it explicitly.
The region default is an example, not the expected deployment. The backend region
is configured separately in `backend.tf`.

Cost controls:

- **Idle stop:** the installed timer checks every five minutes and scales the group
  to zero after `idle_stop_minutes` (default 30) without observed remote job markers
  or running .NET/Docker builds, provided no SSH session is younger than that
  interval. A job marker counts while it is younger than that interval or while a
  process still works inside its checkout, so a killed lane run cannot keep the
  host up. Failed activity inspection leaves capacity unchanged. The instance
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
- **Registration cleanup.** Before either runner starts on boot, a root service
  removes offline, non-busy registrations with build-host names from this runner
  group, including leftovers from abrupt termination. Each runner's root-owned
  registration ID is removed after service exit, including shutdown. A five-second
  IMDS spot-notice check stops both runners to deregister before interruption.
  Other runner groups, online runners and unrelated names are left alone.
- **Isolation.** Each runner is its own account (`gate-runner-N`): no sudo, not in
  the `docker` group, no access to `/home/ubuntu` (lane checkouts and SSH keys),
  `NoNewPrivileges`, and other users' processes are hidden. Its containers run in
  its own rootless Docker, so container root maps to an unprivileged subordinate
  UID rather than host root. An `iptables` owner rule rejects instance metadata
  (169.254.0.0/16, `fd00:ec2::254`) for the account and its rootless network stack,
  so jobs cannot obtain the instance role.
- **Job admission.** GitHub assigns a job by the labels its workflow file names, so
  the host decides which jobs run. Every runner starts with a root-owned job-started
  hook, `/usr/local/bin/honua-gate-runner-admit.sh`, which the runner calls after a
  job is assigned and before its first step. The hook admits a job only when the
  event's pull request head and triggering workflow run belong to the repository
  that owns the run. For any other source, or an event that cannot be read, the
  hook ends the runner's worker process, so the job fails and none of its steps
  start; the service then registers again for the next job. A runner does not start
  when the hook is missing or is not owned and writable by root alone. The heavy and
  light pools share this bootstrap and the same rule. A runner keeps the environment
  it started with, so after a live rerun of the bootstrap the hook applies from each
  runner's next start: restart idle runner services, never busy ones. Do not remove
  the hook while runner services are active. A refusal is recorded in the host journal
  under `honua-gate-runner-admit`; the job itself ends as a lost worker. An admitted
  job's `Set up runner` step logs that a job started hook is configured. To try the
  hook by hand, run it from a throwaway shell (`bash -c 'bash <hook>; echo admitted'`),
  because a refusal ends the calling process.
- **Published ports.** The shared installer assigns each runner a disjoint 768-port
  dynamic range within `20000-32287` (up to 16 runners). Rootless Docker stays in
  RootlessKit's attached child network namespace so its allocator reads that
  runner's range. This prevents separate daemons from selecting the same dynamic
  host port for service containers. Startup fails if the host ephemeral range
  overlaps this pool; the host sysctl is never changed. Explicit fixed port
  publications and other host listeners still require separate coordination.
  The assignment lives in both the new account and its pristine reset template.
  Updating the bootstrap source does not change existing hosts: activation needs
  a separately approved maintenance rollout and a concurrent two-runner service
  container canary before retrying blocked jobs.
- **Resources.** Each runner and its containers share one slice capped at
  `gate_runner_cpu_quota_percent` (default 600, six vCPUs) and
  `gate_runner_memory_max_gib` (default 16). Two gate jobs at the cap consume up to twelve vCPUs and 32 GiB, before
  lane builds and OS overhead. These are shared ceilings, not dedicated capacity reservations.
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
  `pull_request` runs and the exact `ref:refs/heads/trunk` subject of the
  configured repository). No wildcard branch, tag or environment subjects are
  trusted. This also lets trusted trunk certification workflows read the existing
  instance/heartbeat through their bounded advisory selector. The selector does
  not wake or resize the host, and still reserves two idle heavy runners for
  required PR checks. This trust change requires a plan and apply from merged
  trunk before those workflows can select heavy compute; until then they keep
  their hosted fallback. That role can describe Auto Scaling
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


## Updating the heartbeat independently

MAIN activates heartbeat changes after source review and normal PR gates. Do not
rerun the bootstrap installer on a live host to update this one script: it also
changes runner configuration, resource limits and services.

1. Resolve the existing `honua-gate-runner-heartbeat.service` `ExecStart` and
   inspect the current script, timer and configured runner pools. The deployed
   target can be under `/usr/local/bin` even when bootstrap uses
   `/usr/local/sbin`. Stop if the target is a symlink, is not root-owned, or the
   existing gate-count loop differs from the reviewed source. Record its hash,
   mode and service definition; retain a root-only backup outside the target.
2. Extract only the `HEARTBEAT` heredoc from the reviewed full commit. Check it
   with `bash -n`, compare the gate-count loop with the backup, and install a
   root-owned mode-0700 temporary file alongside the existing target. Atomically
   rename that file over the target. Preserve its path, service and timer,
   credentials, instance configuration and all running runner services.
3. Let the existing thirty-second timer publish normally. Read the existing SSM
   parameter and verify the current instance, a nonfuture timestamp no older
   than ninety seconds, unchanged gate-count semantics and version-1 heavy
   availability matching configured, labelled, active idle heavy runners.
   Validate busy-gate/idle-heavy and missing/stale proof with consumer fixtures;
   do not dispatch extra CI or restart jobs to create those states.
4. If verification fails, atomically restore the root-owned backup at the same
   path and wait for the normal timer publication. Confirm the old gate payload
   returns. The consumer must use hosted heavy runners when the additive field
   is absent. Preserve both hashes, verification evidence and rollback receipt.

## Heavy test-shard runners

With `gate_runner_enabled`, `heavy_runner_count` (default 8, at most 8) adds runners for honua-server's server
test shards with the same machinery and isolation as the PR Gate runners. They are
labelled `self-hosted, linux, x64, honua-heavy`, join the organization runner group
`honua-heavy` (create it like `honua-server-gate` above, limited to honua-server),
and are numbered after the gate runners (`gate-runner-3` onwards with two gate
runners). Each runner slice is capped at `heavy_runner_cpu_quota_percent` (default
800) and `heavy_runner_memory_max_gib` (default 16, a hosted runner's memory); eight
runners at the defaults are ceilings, not reservations, on the 64-vCPU host. The heartbeat's existing `idle` field counts only gate runners, so heavy jobs
never change the two-producer admission threshold. Its additive
`heavy: {"version": 1, "idle": N}` field independently counts configured heavy
runners with the `honua-heavy` label, an active runner service, a Listener and no
Worker. Invalid pool definitions, more than eight heavy runners or more than ten
total runners publish zero heavy availability. Consumers must validate the outer
current instance and timestamp (at most 90 seconds old, never in the future),
version 1 and an integer idle count from 1 through 8 before routing heavy work.
Missing or rejected proof selects GitHub-hosted compute. This is availability
observation, not slot reservation; concurrent runs can still queue.
The first two heavy runners stay heavy-only (or all runners when fewer than
three are configured). Before each one-job registration, the remaining heavy
runners inspect queued jobs in queued, in-progress, waiting, pending and requested
workflows in `gate_runner_repository`. When none requests `honua-heavy`, their
registration also advertises `honua-light`. This keeps the existing runner group,
CPU/memory limits, cleanup and heartbeat semantics. No additional instances or
runner accounts are created. The build producer does not offer light overflow.

Queue inspection uses a separate, repository-scoped installation token with
Actions read permission; it is revoked after registration. The App needs Actions
read permission on the configured repository in addition to its existing runner
registration permission. If permission is unavailable, inspection fails, or an API
search reaches its 1,000-result limit, the runner registers heavy-only. The token
never enters the job's home. Both workflow and job lists are paginated.

GitHub does not provide label priority or atomic queue inspection/registration.
An overflow runner may accept a light job just before heavy work arrives; the two
reserved runners continue serving affected shards, and each overflow runner
checks again after its single job. This bounds contention rather than preempting
light jobs. Light routing must retain the same-repository guard and the runner
group's repository restrictions.

Heavy jobs start PostGIS as a service container. The Actions runner reads
`/proc/1/cgroup` before it starts one, so heavy runners use `ProtectProc=default`:
they can list other processes and their command lines, but other accounts'
environments and memory stay unreadable, and `/home/ubuntu` stays inaccessible.

- **Temporary files.** Each job exports `TMPDIR` inside its private home. Fixed-name
  test directories therefore cannot inherit another runner account’s ownership.
  The temporary root is reset with that home after every job.
- **Workspace cleanup.** When a job ends, the service stops the account's rootless
  Docker and empties its home, including `runner/_work`, images and volumes. The
  next start restores the pristine home before registering again.
- **Disk guard.** Lane builds share the root volume. A runner registers for its next
  job only while at least `runner_min_free_disk_gib` (default 40) is free, and
  retries every 15 seconds otherwise.
- **Routing.** honua-server sends part of its shard matrix to these runners when the
  repository variable `HONUA_HEAVY_RUNNER` holds the runner JSON
  (`{"group":"honua-heavy","labels":["honua-heavy"]}`); unset, every shard runs
  hosted. Fork pull requests always run hosted.

The overflow policy can be applied to the running build host without replacing
the instance. Terraform updates launch-template user data; that alone does not
update a running host. After the merged change is applied, use the live runner
convergence below. Existing registrations retain their labels until their next
job/registration cycle; drain and restart only idle services when immediate
registration is needed. Do not restart busy runner services.

Rolling these runners out does not need a new host. The installer is idempotent:
it skips prerequisites already installed for the pinned runner version, provisions
only missing accounts and rewrites every runner's limits, so rerunning the applied
launch template's runner bootstrap converges the running host without touching
running jobs. Runner-enabled user data uses cloud-init’s native gzip decoding for Docker,
build tools, and runner setup together to stay below EC2's 16 KiB limit; full-line `# `
comments are also dropped from the embedded scripts (the files keep them). Extract only the runner section
for a live convergence; the idle timer still installs before network bootstrap:

```bash
# After terraform apply, on the operator machine:
aws ec2 describe-launch-template-versions --region "$BUILD_REGION" \
  --launch-template-name "$(aws autoscaling describe-auto-scaling-groups --region "$BUILD_REGION" \
    --auto-scaling-group-names honua-lane-build-host \
    --query 'AutoScalingGroups[0].MixedInstancesPolicy.LaunchTemplate.LaunchTemplateSpecification.LaunchTemplateName' --output text)" \
  --versions '$Latest' --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' --output text |
  base64 -d | gunzip |
  sed -n '/^(umask 077 && cat > \/etc\/honua-gate-runner.json)/,$p' > runner-bootstrap.sh
ssh ubuntu@"$BUILD_HOST" 'sudo bash -c "apt_retry() { apt-get \"\$@\"; }; set -euo pipefail; source /dev/stdin"' < runner-bootstrap.sh
```

### Runner process cleanup and running-host convergence

Each runner service uses `KillMode=control-group` for its job processes. Each
account's systemd user manager, which runs its rootless Docker, is the system
service `honua-gate-user@N.service` (same `KillMode`), not a lingering
`user@UID.service`: stopping a lingering user's manager makes systemd-logind
stall every new login for about 25 s (honua-iac#543). The unit mounts a private
`/run/user/UID` tmpfs (10% of RAM, as logind would) and removes it on stop. The
pre-job and post-job hooks stop only that unit. On a host bootstrapped before
this change, the first hook after a job also disables the account's linger and
stops its old `user@UID.service`, once. Cleanup must never signal processes by
UID or stop `user-UID.slice`: rootful containers can share the numeric UID, and
that slice also contains the active runner service.

This correction applies to the existing host through the live convergence above;
no host replacement is required. Apply the versioned launch-template change and
rerun only its runner bootstrap. The prepare hook is replaced atomically, and
`daemon-reload` updates the unit configuration without restarting active jobs.
The next natural job stop/start uses the corrected cleanup. The operator owns
this rollout; source validation alone does not prove the installed cohort stable.

The offline bootstrap suite checks both lifecycle hooks and cleanup configuration.
Its opt-in systemd fixture creates a temporary system account and three uniquely
named transient services with that UID in separate cgroups, runs the production cleanup function
in `ExecStartPre` and `ExecStopPost`, and checks the foreign service survives while
runner/manager processes stop. Only the manager unit name and filesystem cleanup
are substituted; process signaling uses real systemd and kernel cgroups. The
fixture removes its services and account afterward. CI runs:

```bash
sudo env HONUA_SYSTEMD_CGROUP_TEST=1 python3 -m unittest discover \
  -s infrastructure/terraform/bootstrap/aws-build-host/tests \
  -p test_gate_runner_cleanup.py -v
```

### PR Gate tool and environment contract

The three selected jobs (`pr-gate`, `fast-tests`, `format`) use the same image.
The dependency audit covers `lean-gate`, `format-check`, `managed-test-artifacts`,
`setup-dotnet-ci`, their admission/generation/build/boot scripts, and the
conditional public installation proof in honua-server's PR Gate workflow.

| Consumer | Required tools and provisioning |
| --- | --- |
| Checkout, admission, classification, scope and retry scripts | Bash, git, gh, jq, the libcurl command-line client, OpenSSL, coreutils (including timeout, sha256sum, base64, realpath), findutils, grep, sed, awk, procps and util-linux. Ubuntu/base installers provide these; the runner installer adds gh from GitHub's signed official apt repository. |
| Python admission fixtures, certification/CITE contracts, scope planners, managed artifact packing and generated indexes | Python 3 with its standard library (including venv, unittest, sqlite3, ssl, tarfile and compression modules); pip and `PyYAML>=6,<7` for `okf-requirements.txt`. Distro python3-venv/pip/yaml plus a private venv with system-site-packages keep pip installs off the system interpreter. |
| Markdown command policy | PowerShell 7 from Microsoft's official Ubuntu repository; it runs in both lean-gate and the docs-only exit. |
| Managed builds, format, generators and tests | setup-dotnet installs the workflow/global.json SDK into writable storage: `$HOME/.dotnet` by default; setup-dotnet-ci overrides this with `$RUNNER_TEMP/honua-managed-sdk/<sdk>` for managed artifacts. Existing native dependencies include ICU, OpenSSL, zlib, fontconfig/DejaVu and libatomic; the runner dependency installer completes the runtime prerequisites. |
| Testcontainers PostGIS, boot/migration smoke, public installation proof | Docker engine/CLI, buildx and Compose from Docker's official apt repository. Each runner uses its own rootless daemon through DOCKER_HOST/XDG_RUNTIME_DIR; host PostgreSQL/psql is unnecessary because psql runs inside the image. |
| Managed artifact npm dependencies | Host Node 24 and npm from NodeSource's official 24.x repository. The managed action declares Node >=24. JavaScript actions also use the runner distribution's bundled Node runtime. Enabling runners upgrades the base image's Node 22 to 24. |
| SDK/Python downloads, caches and artifact archives | tar, gzip, xz, zip, unzip and zstd; the HTTP download client and CA certificates. RUNNER_TOOL_CACHE/AGENT_TOOLSDIRECTORY point to `$HOME/.cache/toolcache`, allowing setup-python's conditional Python 3.11 installation without privileged writes. The installation proof creates its own SDK venv. |
| Locale, time and limits | locales/tzdata; LANG=LC_ALL=C.UTF-8, TZ=UTC, and a 65,536 soft / 524,288 hard open-file limit. Culture-specific tests set their own culture. No extra process-limit override is needed. |

The workflow's hosted-image disk cleanup uses best-effort `sudo ... || true`;
it grants no privileges to these accounts. GitHub/AWS CLIs used by the hosted
`runner-select` job are separate from this image's job requirements. The root
registration/heartbeat service uses the existing AWS CLI; jobs cannot access
its credential or instance metadata.

Before GitHub registration and again before starting Runner.Listener,
`honua-gate-runner-check` verifies required
executables, Node/PowerShell/PyYAML compatibility, writable SDK/tool caches,
locale/time/open-file limits, and rootless Docker/buildx/Compose. A failing image
cannot advertise idle readiness. Each pristine home template is root-owned and
stored beneath a root-only parent; restore explicitly transfers ownership of the
copy to its unprivileged account. SDKs, Python installs and caches are disposable
and reset with every job. No secrets are baked into the template.

Validate locally without cloud access:

```bash
terraform fmt -check -recursive infrastructure/terraform
terraform fmt -check -recursive docs/devops/examples
terraform -chdir=infrastructure/terraform/bootstrap/aws-build-host validate -no-color
terraform -chdir=infrastructure/terraform/bootstrap/aws-build-host test -no-color
python3 -m unittest discover -s infrastructure/terraform/bootstrap/aws-build-host/tests -p 'test_*.py'
```

A passing local test does not prove a replacement image or workflow run. After
the operator applies and replaces the drained host, verify both services stay
ready, then enable the repository selector and record a normal non-skipped PR
run's job conclusions, `i-` runner names, execution and queue times. Compare build
10–14 minutes, fast tests 6–12 minutes and format 8–21 minutes before expanding
the runner workload. Server test shards use the heavy runners above, not these.

### Shared NuGet fallback folder

Each job starts with an empty home, so without a host copy every job downloads
the ~1.7 GB NuGet package archive from the Actions cache (measured 18 Nov 2026:
Setup .NET 77-86 s on these runners against 31 s hosted, about 50 s of it the
archive). `install-nuget-fallback.sh` adds `honua-nuget-fill`, a system account
with no credentials. Its timer checks honua-server trunk every two hours. When
the package inputs (`*.csproj`, `*.props`, `*.targets`, `NuGet.config`,
`global.json`) change, it restores `Honua.sln` with the trunk-pinned SDK into
`/var/lib/honua-nuget-fallback/staging`. A root `ExecStopPost` step runs after
systemd has killed the unit's processes, and only for a successful fill. It
moves the staged tree into a root-only directory and refuses it if it holds
anything other than regular files and directories. It then publishes it as a
root-owned, read-only `gen-<hash>` and repoints `current` (only ever to a
root-owned generation).

- Trust: the account cannot reach instance metadata (`IPAddressDeny`) and can
  write only `staging/` (`ProtectSystem=strict`). It runs trunk's restore, which
  is merged code, with a throwaway HOME and a per-run SDK. No run can change
  an SDK, user config or package that a later run or job uses. Runners and the
  fill account cannot write published generations.
- Source mapping: the fill uses the repository's `NuGet.config`. GitHub
  Packages refuses the account, so private packages are never fetched, and
  every `honua.*` directory is deleted before publication. A job therefore
  cannot get a Honua package from nuget.org through this folder.
- Only complete packages (with `.nupkg.metadata`) are published. A restore with
  fewer than 100 packages, or fewer than 90% of the current generation's count,
  keeps the current generation. A missing or stale package costs the job a
  normal download, never a different package.
- The fill waits while free disk is below the runners' `min_free_disk_gib`
  plus 20 GiB. `current` and the previous generation are kept. A job that pins
  a generation can lose it only if trunk's package inputs change twice while
  it runs.

The runner environment exports `HONUA_NUGET_FALLBACK=/var/lib/honua-nuget-fallback/current`.
The light runners share that environment file but have no folder. A consumer
must treat a missing path as "no fallback". Pending honua-server change:
`setup-dotnet-ci` will use the folder only for jobs that opt in and only when it
resolves to a read-only generation, and will then skip the Actions cache
archive. Until then nothing reads it. After apply and a bootstrap rerun, check
`systemctl status honua-nuget-fallback-fill` and `readlink /var/lib/honua-nuget-fallback/current`.

### Spot drain and CPU budget

On the two-minute spot warning, the notice service creates a root-owned volatile
`/run/honua-gate-runner-draining` marker before stopping heartbeat publication and
all runner services together. Service conditions and checks before registration
and listener startup prevent restarts from admitting more jobs. The marker lasts
until reboot. Stopping the listeners sends GitHub's runner-shutdown signal;
GitHub records interrupted jobs as failed, rather than transparently reassigning
a running job. The honua-server full-CI shutdown observer requests one retry of
those failed jobs after the attempt completes. Successful jobs are retained;
product failures and second interruptions remain failures.

The default eight heavy ceilings total 64 vCPUs (8 × 800%); the two gate ceilings
add 12 vCPUs (2 × 600%). These independent ceilings permit 76 vCPUs of demand on
the 64-vCPU host and guarantee no lane-build headroom. They are not reservations.
Do not infer a reserved CPU budget from an idle heartbeat. Changing the ceilings
requires Terraform configuration and the documented bootstrap rollout; this
change does not apply infrastructure or silently change active job limits.

The light-host configuration also supplies the shared installer's per-account
`runners` array and 40 GiB free-disk floor. Light accounts retain their configured
CPU and memory ceilings and enable service-container process visibility. Their
heartbeat counts idle light listeners without advertising heavy capacity.
