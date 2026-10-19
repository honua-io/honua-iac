---
type: guide
title: "Retain standing certification packets through encrypted transfer"
description: "Encrypt unapproved packets to a pinned local recipient and receive exact-run artifacts privately."
tags: [aws, certification, operators, encryption]
---

# Encrypted standing-certification packet transfer

This Linux amd64 transport encrypts the standing-cert private packet format to
a reviewed local recipient. Its receiver downloads the exact GitHub run artifact
itself, authenticates decryption and retains exact packet bytes privately. It
performs no Terraform, AWS, approval, deployment, IAM, KMS, secret creation or
key-adoption operation. It remains a partial prerequisite under honua-iac#149/#118
and honua-release#282/#652.

The protected server workflow now prepares reviewed inputs on an ephemeral
GitHub-hosted runner, produces a v2 sealed-staging packet and exports only the
encrypted evidence. It has not been dispatched against AWS. Operator-supplied
protected request/tfvars/backend values, existing state and role permissions,
independent local recovery/reviewer custody, and trusted approval/apply consumer
remain separate prerequisites. V1 persistent-retention requests still refuse
GitHub-hosted storage; v2 must match the configured recipient before any
credentialed step.

## Dedicated local identity and reviewed recipient

Use the maintained [age CLI and format](https://github.com/FiloSottile/age),
version `v1.3.2`, native X25519 recipients only. Source pins the official Linux
amd64 archive and both executable SHA256s. The installer extracts only `age` and
`age-keygen`; release signature-proof verification is not claimed. No bundled
plugin, inherited cloud credential or loader override reaches encryption tools.

Install the verified tools into an existing private cache:

```bash
install -d -m 700 "$HOME/.local/state/honua/cert-plan-tools"
python3 infrastructure/terraform/validation/scripts/aws/cert_plan_envelope.py \
  install-tools --directory "$HOME/.local/state/honua/cert-plan-tools"
```

The dedicated recipient is now pinned in the reviewed source policy. Its
private identity is held only in the local owner-only
`$HOME/.local/state/honua/aws-cert-plan-identity/` directory as `identity.txt`
(`0600`), with a local `custody.json` recording the public recipient and
fingerprint. The identity was created with the verified tool using exclusive
creation; do not generate another identity for this recipient. To inspect its
public half without exposing private bytes:

```bash
"$HOME/.local/state/honua/cert-plan-tools/age-keygen" \
  -y "$HOME/.local/state/honua/aws-cert-plan-identity/identity.txt"
```

This is a local file-encryption key, distinct from audit, connection key-ring,
approval HMAC and deployment credentials. Never send its private identity to
GitHub or a cloud service. Only the public recipient from `age-keygen -y` is
published; no AWS resource is needed for this output path.

The tracked `release/aws-cert-plan-recipient.json` binds the public `age1…`
recipient and SHA256 of its UTF-8 bytes without a newline. The local identity
currently has no independent backup; a same-host copy would not supply one.
Before depending on encrypted evidence for retention, the custodian must
arrange independent recovery and reviewer access without sending the private
identity to GitHub or a cloud service.
Both tools require clean tracked configuration. A caller-selected dispatch
recipient would disclose secret-bearing plans and is not accepted. Persistence,
backup, custody, retention and independent reviewer access remain operator
responsibilities; local permission checks do not establish those properties.

## Fixed trusted sealing contract

The trusted server job must be `workflow_dispatch` from
`honua-io/honua-server`, `refs/heads/trunk`, workflow
`.github/workflows/standing-aws-cert-plan.yml`, with identical full
`GITHUB_SHA`/`GITHUB_WORKFLOW_SHA`, matching workflow ref and positive run/attempt.
The receiver independently verifies GitHub records; environment strings alone
are not execution authentication. The clean IaC checkout must match the
producer receipt's `iacRevision` and contain the reviewed recipient at that SHA.

```bash
python3 infrastructure/terraform/validation/scripts/aws/cert_plan_envelope.py \
  seal --packet "$PRIVATE_PACKET" --producer-receipt "$PRIVATE_PRODUCER_RECEIPT" \
  --output-directory "$PRIVATE_EXPORTS" --tools-directory "$VERIFIED_AGE_TOOLS"
```

Inputs/files are private `0600`, directories `0700`, with non-replaceable
ancestors. The new export contains exactly `plan.age` and `receipt.json`. The
safe receipt binds repository/workflow/ref/head/run/attempt, IaC/candidate,
original plan/metadata/packet hashes, recipient fingerprint, cipher hash and
expiry. Status is `encrypted-awaiting-local-retention`, approval `not-approved`,
qualification `not-evaluated`. No private locator, resource plan or diagnostic
is public.

The workflow uploads only those two explicit files as artifact
`standing-aws-cert-plan-<runId>-<attempt>` and clean only its owned transient
plaintext on every exit. Never upload the original packet or a workspace glob.
This source slice does not dispatch the workflow. Upload success does not
prove local retention.

## Exact-run private receiver

Create a `0600` expected-context JSON file from the reviewed producer/candidate
and selected real run, rather than an untrusted downloaded receipt:

```json
{
  "schema": "honua.aws-cert-plan-receive/v1",
  "runId": 12345,
  "attempt": 1,
  "workflowHeadSha": "REPLACE_WITH_REVIEWED_SERVER_WORKFLOW_SHA",
  "iacRevision": "REPLACE_WITH_REVIEWED_IAC_SHA",
  "candidateDigest": "REPLACE_WITH_APPROVED_CANDIDATE_SHA256"
}
```

```bash
python3 infrastructure/terraform/validation/scripts/aws/cert_plan_envelope.py \
  receive --expected "$PRIVATE_EXPECTED_CONTEXT" --identity "$PRIVATE_AGE_IDENTITY" \
  --output-directory "$PRIVATE_RETAINED_PACKETS" --tools-directory "$VERIFIED_AGE_TOOLS"
```

Using existing operator GitHub read authentication, the receiver calls
`gh api --hostname github.com` for the actual run/attempt, checks repository,
source SHA, branch, workflow path, event and success, and downloads the unique
artifact itself. It accepts no caller-authored execution record. Artifact digest
and source/run metadata, exact ZIP entries, recipient, cipher/producer hashes,
candidate/IaC identity and expiry must match.

Authenticated decryption must finish in private temporary storage before
extraction. Only twelve exact packet filenames are accepted, including the retained
`bootstrap.zip`, `bootstrap-inputs.json` and `module-inputs.json` deployment
input bindings (including locked provider-package hashes). Traversal/absolute,
duplicate, link, sparse/device, unexpected and oversized entries are refused.
Private packet file content is bounded to 255 MiB, leaving a 1 MiB margin for
the tar, age and GitHub artifact containers; each complete transferred
container is bounded to 256 MiB. This is a transport limit, not a server
workload limit. No archive-controlled path or permission is applied.

Success atomically publishes `aws-cert-retained-…/` containing `packet/` and a
private `receipt.json`, files `0600`, directories `0700`, without overwriting
existing retention. Status is `retained-unapproved`, approval `not-approved`,
qualification `not-evaluated`. Wrong-recipient/run, tampered or interrupted
transfers produce no completed retained directory.

This layer checks transport and exact bytes. Full Terraform source/backend/state/
identity/input semantics stay producer/verifier-owned; integration must run that
exact packet verifier before approval. Encryption and a green GitHub run are not
human approval. Signed exact-byte authority and one-time execution remain
required; no apply command exists here.

## Synthetic controls

```bash
HONUA_CERT_TEST_TOOLS="$HOME/.local/state/honua/cert-plan-tools" \
  python3 infrastructure/terraform/validation/scripts/aws/test_cert_plan_envelope.py -v
```

Tests use real pinned age executables, disposable local fixture identities,
authored packets and a fake GitHub API. They cover exact round trip, real
authentication failure despite a matching outer hash, wrong recipient/source/
run/candidate, artifact substitution, unsafe authenticated archive content,
expiry and private output. They do not execute AWS or qualify a candidate.
