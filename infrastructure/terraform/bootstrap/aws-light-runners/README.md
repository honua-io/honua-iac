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

The security group has no inbound rules; use SSM Session Manager. The host role can read only
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
forks always stay hosted.

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
