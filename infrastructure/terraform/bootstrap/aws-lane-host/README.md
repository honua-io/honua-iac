# Lane host

An on-demand Ubuntu 24.04 instance that runs headless Claude Code release lanes, so they do not
run on an operator workstation. Heavy .NET work still goes to the Spot build host
(`bootstrap/aws-build-host`), which this host wakes and reaches over SSH.

- One on-demand instance (default `m6i.4xlarge`: 16 vCPU, 64 GiB), Elastic IP, SSH only from
  `allowed_ssh_cidrs`, plus SSM Session Manager. No other inbound access.
- A separate encrypted gp3 data volume (default 500 GiB) mounted at `/home/ubuntu/lanes`. It has
  `prevent_destroy` and survives instance replacement. `/home/mike` links to `lanes/home`, so lane
  scripts written with workstation paths run unchanged under the `ubuntu` account.
- Bootstrap installs Docker, Node 22, a pinned Claude Code, gh, the AWS CLI, the .NET 10 SDK (for
  read-only MSBuild queries) and rtk, checksum-verified.
- A monthly budget alert on the instance's on-demand compute.

## Secrets

Credentials never enter Terraform state. Create three SecureString parameters under
`parameter_prefix` (default `/honua/lane-host`) before the first apply, reading each value from a
file so it is never echoed:

| Parameter | Contents |
|---|---|
| `claude-credentials` | Claude Code login (`~/.claude/.credentials.json`) |
| `github-token` | GitHub token for the lane account |
| `build-ssh-key` | Private key the build host accepts for `ubuntu` |

```bash
aws ssm put-parameter --region eu-north-1 --type SecureString --overwrite \
  --name /honua/lane-host/claude-credentials --value file://$HOME/.claude/.credentials.json
```

At every boot `honua-lane-secrets.service` writes the GitHub token and SSH key. It keeps an
existing Claude login because Claude Code rotates it in place; run
`sudo honua-lane-secrets --replace-claude` after updating that parameter.

## Apply

```bash
cp backend.tf.example backend.tf   # set the state bucket
terraform init
terraform apply \
  -var 'allowed_ssh_cidrs=["203.0.113.10/32"]' \
  -var "ssh_public_key=$(cat ~/.ssh/honua-build.pub)" \
  -var "budget_alert_email=$ALERT_EMAIL"
```

`build_host_ssh_access` adds an SSH rule for the lane host's address to the build host security
group. The build host manages its ingress inline, so also list that address in the build host's
`allowed_ssh_cidrs`; otherwise its next apply removes the rule.

The instance ignores AMI and user data changes so an apply never interrupts running lanes. To
rebuild it, stop the lanes and run `terraform apply -replace=aws_instance.lanes`; the data volume
reattaches with every worktree and log intact.

Stop the instance when no lanes run (`aws ec2 stop-instances`); stopped, only the volumes and the
Elastic IP bill.

## Idle stop

`honua-lane-idle-stop.timer` checks every minute and stops the instance after
`idle_stop_minutes` (default 30) of continuous inactivity. EC2 shutdown behavior is
`stop`, so the instance and disks remain available for a later start. This does not
provide automatic wake-up for new CI events. Existing hosts ignore user-data changes;
install the checker and installer explicitly to retrofit them without replacement.

Before enabling useful idle detection, write a root-owned
`/home/ubuntu/lanes/idle-stop.json` on the retained volume:

```json
{
  "work_probe": ["/absolute/path/to/check-pending-work"],
  "passive_commands": [["/bin/bash", "/absolute/path/to/keeper"]]
}
```

The probe runs as `ubuntu`: exit 0 means no pending work; any other exit, timeout,
missing configuration or inspection error prevents shutdown. It must inspect pending
inboxes and queued/deferred jobs, including work waiting between controller passes.
The persistent configuration survives instance replacement. An empty host without a
configured probe remains running until its controller is configured.

All other user processes count as work except standard session daemons, compiler
servers, exact `passive_commands` and their direct `sleep` children. Active children
of passive controllers still count. An optional `passive_processes` map pairs PID
strings with `/proc/PID/stat` start times, preventing exemptions after PID reuse.
Never exempt a dispatcher that can start work without participating in admission.

Launchers must hold a shared read-only flock on
`/run/lock/honua-lane-activity.lock` through admission, capacity waits, and child work.
After acquiring it, refuse new work if `/run/honua-lane-stopping` exists. The checker
holds the exclusive lock through its final activity check and stop request. Keep the
lock inode intact while installing or updating launchers. Low CPU usage alone does
not indicate idleness.

A controller service stored at
`/home/ubuntu/lanes/host-services/honua-lane-keeper.service` is restored by bootstrap.
It must order itself after the retained mount and `honua-lane-secrets.service`, and
preserve running lane children during controller maintenance. On an existing host,
install and enable this unit after safely adopting any existing keeper process.

Inspect without advancing the timer or stopping anything:

```bash
sudo /usr/local/sbin/honua-lane-idle-stop --check
systemctl status honua-lane-idle-stop.timer
sudo journalctl -u honua-lane-idle-stop.service
```

Disable automatic stop with `sudo systemctl disable --now honua-lane-idle-stop.timer`.
