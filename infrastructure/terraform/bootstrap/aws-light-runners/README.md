# Light runner pool

One Spot host (about 32 vCPU and 64 GiB; twelve equivalent amd64 pools, `capacity-optimized`,
capacity rebalance on) that runs `runner_count` (default 12) ephemeral GitHub Actions runners
for short CI jobs: clean-code, hygiene, attestations, docs checks, labelers and similar. Heavy
build and test shards stay on GitHub-hosted runners.

The host reuses the build host's gate runner bootstrap
(`../aws-build-host/install-gate-runner.sh`), so each runner:

- is an unprivileged account with its own rootless Docker and a CPU/memory slice
  (`runner_cpu_quota_percent`, `runner_memory_max_gib`);
- gets a pristine home before every job;
- uses its own dynamic published-port range within `20000-32287`, as described in
  the [shared bootstrap](../aws-build-host/README.md#pr-gate-runners-off-by-default);
- registers just in time for exactly one job through the GitHub App credential;
- has no route to instance metadata, so jobs cannot use the host role.

Runners register in the organization runner group `runner_group` (default `honua-light`) with
labels `self-hosted, linux, x64, honua-light`. The group must exist first and grant the
repositories that use the label; public repositories need "Allow public repositories".

By default the security group has no inbound rules; use SSM Session Manager. The host role can read only
its own credential parameter and write its heartbeat parameter.

## Credential

Terraform copies the App id (`github_app_id_parameter`) and private key
(`github_app_key_parameter`) into `/honua-light-runners/github-app` as a write-only value, so the
key never enters state or plan output. After rotating the key, increase
`github_app_credential_version` and apply.

## Workflows

Repositories opt jobs in with:

```yaml
runs-on: ${{ vars.HONUA_LIGHT_RUNNER && (!github.event.pull_request || github.event.pull_request.head.repo.full_name == github.repository) && (!github.event.workflow_run || github.event.workflow_run.head_repository.full_name == github.repository) && fromJSON(vars.HONUA_LIGHT_RUNNER) || 'ubuntu-latest' }}
```

Setting the repository variable `HONUA_LIGHT_RUNNER` to `["self-hosted","honua-light"]` moves
them; deleting it returns them to hosted runners. Pull requests and `workflow_run` events from
forks always stay hosted. The host applies the same rule independently of workflow routing and
refuses such jobs: see job admission in the
[shared bootstrap](../aws-build-host/README.md#pr-gate-runners-off-by-default).

## Apply

Inputs live in SSM SecureString `/honua/gate-runners/tfvars` (eu-north-1). Copy
`backend.tf.example` to `backend.tf`, then:

```bash
aws ssm get-parameter --region eu-north-1 --name /honua/gate-runners/tfvars \
  --with-decryption --query Parameter.Value --output text > "$HOME/light-runners.tfvars"
terraform init && terraform apply -var-file="$HOME/light-runners.tfvars"
```

Desired capacity zero stops the pool. A monthly budget on EC2 compute for these instance types
in the region emails `budget_alert_email` at 80% actual and 100% forecast of
`monthly_budget_usd` (default 750); alerts lag several hours and stop nothing.

## Pre-PR overflow (opt-in)

`pre_pr_overflow` enables one SSH execution account on the existing Spot host, using
an operator-supplied public key and IPv4 CIDR of /24 or narrower. No additional
host, disk, instance size, or On-Demand fallback is added. Keep the existing pool
sizes and set `runner_count = 10` with the default per-runner ceilings to reserve
four CPUs and eight GiB for overflow, plus host headroom. Validation rejects
unreserved capacity and reserves account index 16. Custom instance types must
still meet the documented minimum 32 vCPU / 64 GiB host size.

Example additional inputs (use your operator's actual network and public key):

```hcl
runner_count = 10
pre_pr_overflow = {
  ssh_cidr       = "192.0.2.1/32"
  ssh_public_key = "ssh-ed25519 REPLACE_WITH_PUBLIC_KEY operator"
}
```

The shared build-tool installer supplies the same .NET SDKs as the build host
(currently 10.0.404 and 11.0.100), native build/browser dependencies and Node.
`gate-runner-16` has a private home, SDK copy, NuGet/package caches, checkouts and
rootless Docker daemon. Caches begin cold and persist across sessions; they are
never shared with Actions accounts. Its SSH sessions and containers share a
4-CPU/8-GiB systemd user slice. The shared Docker network wrapper restricts
published ports to index 16's range, `31520-32287`. Instance metadata is blocked
for this account, with a boot service required before SSH and its user services. Passwords, PTYs and SSH forwarding are disabled.

### Router interface

The router must preserve normal build-host admission and checkout ownership.
It uses `gate-runner-16`, with `repos/` and `wt/` under `/home/gate-runner-16`.
The installed SDK/cache environment is loaded for every SSH command.

1. Open a dedicated SSH connection running `/usr/local/bin/honua-pre-pr-session`.
   Keep its stdin open throughout snapshot, sync, execution and copy-back. This
   holds a host-local session lock. If that connection closes while an executor
   still runs, admission stays locked until execution and cleanup finish.
   Only the exact stdout line
   `HONUA_OVERFLOW_ADMITTED` means admission succeeded. Busy, draining, and less
   than 20 GiB free refuse with exit 75 before printing that line.
2. Sync the checkout using a separate SSH connection while holding admission.
3. Execute `/usr/local/bin/honua-pre-pr-exec <command> <arguments...>` in the
   checkout. It loads the private Docker/SDK environment, sets the four-CPU
   build defaults, rechecks disk/draining state, and serializes execution.
4. Copy results back, then close the admission connection's stdin. Fall back to
   the build host only before execution starts. Any execution exit status,
   including 75, is a workload result and must never trigger another execution.

The executor removes containers from this account's private daemon before and
on exit from a command, under its execution lock. A disconnected session's
leftovers are removed before the next execution. Cleanup errors are reported
on stderr without replacing the workload exit status; failed pre-execution
cleanup refuses a new workload. It never stops another
account's containers and does not claim host-wide benchmark exclusivity.
Do not use the overflow account for detached workloads. The router must keep
its admission channel alive until execution and copy-back have completed.

### Deployment and proof

Opt-in adds a rolling instance refresh with zero minimum healthy percentage and
100 percent maximum, so a replacement uses the same single-host allocation.
Drain the existing light Actions pool before applying the opt-in: boot-time
configuration and reduced runner count take effect on replacement, and the
single-host pool is unavailable during that replacement. Removing the option
updates the launch template; replace the host in a coordinated IaC maintenance
change to remove an already-installed account and its SSH configuration.

An apply and replacement by the infrastructure owner are required before any
endpoint or live toolchain proof exists. Before enabling router selection:

- verify SSH access, `.dotnet/dotnet --list-sdks`, rootless `docker info`,
  `nproc`, the user slice limits, private port publication and free disk;
- run the same real pre-PR command on the same commit on each host using the
  approved remote tooling; compare exit status, tests, queue, sync, execution,
  copy-back time and cache state;
- prove a second admission is refused while the first session syncs or runs,
  draining refuses admission, and a workload exit 75 is not rerun elsewhere.

Offline controls run with `terraform test` (Terraform 1.17 or newer for mocked
ephemeral resources) and `python3 -m unittest discover -s tests -v` in this root.
These controls prove bootstrap size, network/resource constraints and execution
behavior; they do not substitute for the live comparison after deployment.

### CodeQL resource budgets

The shared bootstrap sets `CODEQL_RAM` to 60% of each configured runner
`memory_max_gib` in MiB and `CODEQL_THREADS` to the whole CPUs in
`cpu_quota_percent` (at least one). The default 5-GiB, 250% light slot therefore
uses 3072 MiB and two threads. The remaining memory accommodates the runner,
extractors and rootless Docker within the same user slice. This prevents
managed CodeQL default setup from choosing the host's full memory and CPU count.
Workflow-level CodeQL resource inputs can still override these defaults.

The environment is generated in each runner service's root-owned
`55-codeql-resources.conf` systemd drop-in. Updating the bootstrap source alone
does not change installed runners: the infrastructure owner must deploy it
through the existing IaC process and verify a subsequent natural CodeQL run.
No scan language, query suite, gate, or runner count changes with this budget.
