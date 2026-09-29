# aws-demo has moved

This directory used to hold the Terraform for the live `demo.honua.io`
environment. It was extracted to its own private repo,
**[honua-io/honua-demo](https://github.com/honua-io/honua-demo)**, because it
codifies a real running environment (account IDs, VPC/subnet/security-group
IDs, live-drift notes) rather than a reusable example — see
[honua-iac#126](https://github.com/honua-io/honua-iac/issues/126) for the
extraction plan and rationale.

- The Terraform root module now lives at `stacks/aws/` in honua-demo, pinned
  to this repo's `aws-serverless` module by git ref (not a path relative to
  this repo anymore).
- The demo ops runbook and seed-data manifest moved with it.
- honua-demo is **private** — ask a maintainer for access if you need it.

`examples/` in this repo goes back to holding reusable, non-live example
stacks only (see the sibling directories: `aws`, `azure`, `aws-serverless`,
`azure-functions`, `aws-eks`, `azure-aks`, `aws-cert`, …).
