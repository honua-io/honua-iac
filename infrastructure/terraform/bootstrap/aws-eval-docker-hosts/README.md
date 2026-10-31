# Ephemeral AI evaluation Docker hosts

This root creates isolated Ubuntu 24.04 EC2 hosts in a public subnet. Only SSH
from the supplied IPv4 CIDRs is allowed inbound. Docker Engine and Compose are
installed at boot; the `ubuntu` user can run Docker after reconnecting. Docker
group membership grants root-equivalent access. Connect the local agent to each
stack using an SSH tunnel; do not expose application ports publicly. Check
`/var/log/cloud-init-output.log` if Docker is not ready.

Copy `backend.tf.example` to `backend.tf`, replace the bucket placeholder, and
initialize Terraform. Supply the public key corresponding to your private key and
narrow source CIDRs. Apply only from the authorized release session. Obtain SSH
aliases with `terraform output -raw ssh_config` and configure `IdentityFile`
locally. The current AMI is selected through Canonical's public SSM parameter;
a newer AMI may replace hosts in a later plan. Instance type must be amd64.

Every resource that supports tags carries `Environment=it`,
`Lifecycle=ephemeral`, `Owner=ai-arc-eval`, `ManagedBy=terraform`, and both
`ExpiresAt` and `ExpiresAtUTC`. Expiry is anchored to the first apply; changing
`ttl_hours` changes the deadline relative to that original time. Tags are a
cleanup signal, not a shutdown mechanism. The existing validation reaper does
**not** clean these hosts: it requires a GitHub `ValidationRunId`, defaults to
another owner, and cannot terminate EC2 instances. Run `terraform destroy` with
the same variables and state promptly after the evaluation; verify EC2 and VPC
resources are gone. Until reaper support is explicitly added and deployed,
the release operator owns cleanup and cost monitoring. After first apply, update
`bootstrap/drift-roots.json`: its initial `applied=false` expects no state.
