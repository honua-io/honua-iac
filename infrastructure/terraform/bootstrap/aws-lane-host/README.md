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
