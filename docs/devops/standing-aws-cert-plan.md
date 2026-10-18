---
type: guide
title: "Produce a private standing AWS certification plan"
description: "Preserve the existing aws-cert context in an unapproved private exact-plan packet."
tags: [aws, certification, terraform, operators]
---

# Produce a private plan for the standing AWS certification stack

This operator entrypoint produces a saved Terraform plan and an explicitly
**unapproved** private packet for the existing `examples/aws-cert` state. It
does not initialize a backend, create/select a workspace, apply, destroy,
retrieve secret values, adopt keys, or issue approval. It is a bounded release
prerequisite under honua-release#282/#652 and honua-iac#149/#118; it does not
qualify a candidate or supply a standing-cert deployment actuator.

## Required operator decisions

Before execution, the standing certification custodian supplies:

- An approved existing execution runtime using the exact server `cert` OIDC
  subject, a short-lived deployment-role session, and a separate protected
  backend web-identity token file. Both existing roles and contract digests must
  be supplied. This tool never creates or changes IAM trust or acquires a new
  deployment session. Missing role permissions are a prerequisite, not a reason
  to weaken validation.
- An initialized existing backend with its original bucket, key, region,
  workspace and nonempty prior state lineage/serial. The backend must already
  reference the distinct backend role through `assume_role_with_web_identity`
  and `web_identity_token_file`. Preparing that configuration is a separate
  operator action. Do not migrate state, initialize an empty workspace or change
  the state object to make this command pass.
- A persistent private directory owned by the executing user, mode `0700`,
  independent reviewer access, retention deadline and named custodian. Files
  must remain available for exact private review; GitHub-hosted ephemeral
  runners are refused. The declarations record operator responsibilities;
  this tool cannot prove a storage mount is durable or grant reviewer access.
- Approved protected JSON tfvars, including the existing cert key-ring and
  audit-chain key references and all enabled digest-pinned images. The key
  selection/adoption decision is separate from discovery. Preserve existing
  audit history and follow the module's all-writer activation procedure.

These inputs are **not supplied by this helper**. A source/test pass does not
establish a working OIDC runtime, durable retention, approved key adoption, or
trusted standing-cert approval/apply consumer. The current generic DevOps
catalog supports ECS-small; do not describe it as a standing aws-cert actuator.

## Protected request contract

Copy [the request skeleton](standing-cert-plan-request.example.json) to a private
operator directory, set file mode `0600`, and fill every placeholder from the
approved existing context. The skeleton is deliberately non-executable; it is
not an approved deployment configuration. Do not commit the completed request,
tfvars, token or generated packet. Do not put credentials/token contents in the
request. Its `backendTokenFile` names an ephemeral protected file, not a token.

| Field | Required value and source |
|---|---|
| `schema`, `targetId` | `honua.aws-cert-plan-request/v1`, `aws-cert` |
| `actorId` | Named operator/workload actor; not approval authority |
| `iacRevision` | Exact clean current checkout SHA, 40 lowercase hexadecimal characters |
| `candidateDigest` | Approved prepared candidate SHA256, 64 lowercase hexadecimal characters; the helper does not edit selection |
| `accountId`, `region` | Existing cert account and region |
| `terraformVersion`, `providerLockSha256` | Exact installed Terraform version and the root's immutable `.terraform.lock.hcl` SHA256 |
| `backend` | Original `bucket_id`, `object_key`, selected `workspace`, canonical `configDigest` from the maintained backend identity machinery |
| `stateBefore` | Exact existing `lineage` and integer `serial`, obtained through the maintained metadata-only state path |
| `workloadIdentityContract`, `workloadIdentityContractDigest` | Complete existing bootstrap/aws-terraform-oidc output value and its canonical digest; not a caller-invented role receipt |
| `executionIdentityContract`, `executionIdentityContractDigest` | Complete existing bootstrap/aws-exec-identity output value and its canonical digest |
| `sessionExpiresAtUtc`, `expiresInSeconds` | Real deployment-session expiry and plan lifetime (60–1800 seconds). Session and backend token must remain valid for lifetime plus 120 seconds |
| `backendTokenFile` | Absolute nonsymlink `0600` token file matching the initialized backend's token-file path |
| `varFile`, `varFileSha256` | Absolute nonsymlink `0600` JSON tfvars file and exact byte SHA256. Hidden auto tfvars are refused |
| `imagePins` | Exact nonempty image variables from the protected tfvars, each `repository@sha256:…`; Lambda and GP images required, enabled custom-code/ECS fixture images also required |
| `secretReferences` | Exact `audit_chain_key_secret_arn` and `operation_key_ring_certificate_secret_arn` references from approved tfvars, in cert account/region. No key material |
| `privateRetention` | Existing absolute nonsymlink `0700` `directory` outside the source tree, named `owner`, independent reviewer `accessReference`, future `retainUntilUtc` beyond plan expiry |

2026.1 tfvars must explicitly set `licensing_mode = "Disabled"` and
`enable_pro_license = false`, with no nonempty `pro_license_*` inputs. Preserve
the approved existing resource configuration; a full plan can reveal older
unapplied changes. The helper does not declare replacements/deletions safe.

The backend digest uses `scripts/terraform-backend-identity.sh`'s canonical
document, including resolved configuration binding. Do not substitute a hash of
an arbitrary backend file. Identity digests cover the complete existing output
objects. The tool checks those contracts, the exact live roles' OIDC trust and
the actual deployment STS caller. IAM `GetRole` must be available to the
approved runtime. Current trust must be only the existing server `cert` subject,
issuer and audience, with separate roles and maximum one-hour sessions. This
checks trust and identity, not the complete permission-policy least-privilege
proof, which remains separate qualification work.

## Execute plan only

Run from the pinned clean IaC checkout in the approved private runtime:

```bash
python3 infrastructure/terraform/validation/scripts/aws/standing_cert_plan.py \
  --request "$HOME/.config/honua/aws-cert/plan-request.json"
```

The process must already have short-lived deployment STS credentials. No
`TF_CLI_ARGS*`, `TF_VAR_*`, `TF_LOG*`, Git environment overrides,
offline/dirty/local escape hatches, alternative
Terraform binary, provider environment profile/endpoint, loader override,
workspace or data-directory overrides are accepted. Terraform and AWS CLI
installations/PATH and the runtime itself remain trusted operator inputs. The
backend token is sent to AWS by the backend for signature/trust validation;
local claim checks alone are not token authentication. No cloud command is
needed to run the offline tests below.

Protected files must also have trustworthy containing directories: each
ancestor is owned by the executing user or root and is not writable by others
(root-owned sticky temporary directories are permitted). This prevents another
local user from replacing a protected file before Terraform reopens it.

The producer validates context, invokes the maintained exact-plan script once
with `--skip-init` and no `--workspace`, then rechecks context and byte bindings.
No `workspace select/new` or `init` fallback is possible. Planning refreshes
provider data and uses the existing backend lock; it is not a claim of zero
provider side effects.

Success writes a single public JSON receipt with source/candidate digests,
plan/metadata/packet hashes and expiry. Its status is `planned-unapproved`,
approval is `not-approved`, and qualification is `not-evaluated`. Refusals print
only an allowlisted reason code. All child stdout/stderr remains private,
including failures. No account, ARN, backend location, private file path,
resource plan or Terraform diagnostic is copied to stdout/stderr.

## Private packet and review boundary

The custodian finds the new `aws-cert-plan-*` directory in the configured
private retention directory. Each file is `0600`; the directory is `0700`:

- `plan.bin`: exact saved plan; may contain secrets.
- `metadata.json` and `metadata.json.digest`: maintained exact-plan bindings,
  including private account/role/backend references.
- `context-before.json` and `context-after.json`: matching canonical source,
  backend, identity, input and prior-state metadata; no raw state document.
- `request.json`: the private operator request, including secret references.
- `review.txt` and `diagnostic.log`: private Terraform review and all child
  output; may contain secrets.
- `packet.json`: atomically published completed file manifest, SHA256 for every
  preceding file, exact metadata digest and explicit unapproved/unqualified
  status. A partial or failed attempt has **no `packet.json`** and must never be
  presented for approval. Partial files remain private for custodian diagnosis.

Verify the retained packet against `packetSha256` from the original producer
receipt before private review:

```bash
python3 infrastructure/terraform/validation/scripts/aws/standing_cert_plan.py \
  --verify-packet "$HOME/.local/state/honua/aws-cert/aws-cert-plan-<packet-id>" \
  --expected-packet-sha256 '<original-producer-packet-sha256>'
```

This reads private files only, verifies the finite file set, exact byte hashes,
metadata/plan binding and expiry, and returns `verified-unapproved`. Keep the
original receipt independently; recomputing an expected hash from changed files
does not authenticate them. Consistency verification is not operator approval.

Never upload these files with a general artifact glob. Repository names and
the old repository map do not prove privacy: live metadata during investigation
reported honua-server, honua-release, honua-iac and honua-devops as public. Verify
any proposed destination's actual access policy first. Existing release-cell
state sealing creates ephemeral secret material and is tied to disposable
teardown; it is not the standing plan retention contract. Audit keys, connection
key-rings and approval HMAC keys are not interchangeable encryption keys.

Independent authorized review must bind **the exact saved bytes and complete
metadata**, including source/provider/backend/workspace/state/input/account/
role/candidate/action/expiry and one-time operation identity. Review the private
plan for the intended standing-function environment and exact grants; stop on
unexpected replacements, deletions, license access, trust changes or drift.

This entrypoint does not issue or accept approval and contains no apply command.
The later standing-cert consumer must independently validate trusted signed
approval, byte hashes, expiry, context/state and one-time claim. The low-level
`terraform-exact-apply.sh --approved-digest` compares a digest; merely echoing
that digest is not trusted approval. The existing two-principal guide documents
the ephemeral cell roles, not an approved standing-cert verifier grant. Keep
that integration prerequisite open; do not manually apply a packet from this
helper as a workaround.

## Offline controls

```bash
python3 infrastructure/terraform/validation/scripts/aws/test_standing_cert_plan.py -v
```

The controls run the actual maintained Bash plan machinery in a synthetic Git
checkout, with authored fake AWS/Terraform executables and a complete command
journal. They require no AWS credentials/network or Terraform installation.
Tests distinguish private packet production from refusal and prove no init,
workspace mutation, apply or destroy is invoked. They do not prove AWS trust,
state locking, retention access, approval, deployment or candidate qualification.
