The reviewed `foss4g-images.tfvars.json` is byte-identical to the counterpart in
honua-release PR845. It prepares candidate-independent encrypted custody,
scoped roles and immutable image repositories in account 585192672263/us-east-1.
It contains references and monetary reservations only; no secret values or state.
No main Server/Console/Cognito deployment or model invocation is enabled.

The bootstrap workflow checks its exact configuration against the selected
protected release source before obtaining AWS credentials. That source must
be on the observed release trunk and contain the actual funding compiler.
No pre-merge commit is assumed to survive a squash merge. CI waits for the reviewed release prerequisite to land.
Null source/config hashes are explicit compiler inputs, never deployed ledger
identities. The compiler derives actual SHA/file bytes from the original workflow
source and retains original monetary reservations and stable allocation identity.

Original 151 plus 8 USD usage holds, two original 20 USD Lambda obligations,
25 USD foundation infrastructure, 10 USD cleanup and three conservative 20 USD
unsettled model holds remain reserved (294 USD). The next single image allocation
is 5 USD. These are conservative reserves, not measured or settled prices.
Numeric spent 0 does not establish zero account usage: observed gross usage is
157.0291032026 USD, attribution remains unresolved, and later genuine model
receipts remain separate liabilities. Legacy 500/50 and pilot 2000/200 limits stay
distinct. Original receipt hashes/observations live in the reviewed release
funding basis; older unknown costs are not released.

After both source PRs are reviewed and merged, run release
`hosted-pilot-bootstrap.yml` on trunk with this exact config path,
`region=us-east-1` and `mode=plan`. Review actual value-free plan/source metadata
before the governed `mode=deploy` path and its real protected approval. The helper
applies only its exact saved plans and retains encrypted original recovery state.
No AWS mutation, manual Terraform apply, actual approval or deployment is claimed
by this source change. The source deadline is 2026-10-30T00:00:00Z and its funding
metadata expires 2026-10-24T13:45:00Z; a stale allowance must be reconciled through
reviewed source rather than silently renewed.
