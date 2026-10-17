---
type: guide
title: "Configure AWS model transcript signing"
description: "Configure runtime-only AWS signing references, role scope and the approved public verification manifest."
---
# AWS model transcript signing

The maintained ECS and Lambda modules, and the `aws`, `aws-serverless` and
`aws-cert` roots, accept the optional `transcript_signing` object. Its default
is `null`, which adds no signer settings or read/decrypt permissions and preserves
existing additional environment settings. Configuring this input requires both
`key_id` and `secret_arn`; partial pairs, secret selectors embedded in the ARN,
wildcards and inline material fail planning.

| Input | Operator-owned value |
|---|---|
| `key_id` | Stable public verification-manifest key ID, 1–128 letters, digits, dots, underscores or hyphens. |
| `secret_arn` | Complete ARN of an existing Secrets Manager secret containing a base64-encoded 32-byte Ed25519 seed. |
| `version_id` | Optional immutable 32–64-character version ID. Pin it for qualification; empty uses the service's current version. |
| `kms_key_arn` | Optional exact customer-managed key ARN (UUID or multi-region key ID). Empty adds no decrypt grant. |

The operator creates and governs the signing secret outside Terraform. This
configuration neither generates keys nor reads, copies, rotates or outputs secret
values. Keep approved ARNs, version IDs and public key identity in protected
operator inputs and review the saved plan before any separately authorized apply.
The seed must remain separate from application, audit and certification-capture
secrets, and keep it out of request-secret allowlists. Existing secret and KMS
resource policies must admit the exact runtime/execution roles as applicable; an
identity policy alone does not override their resource policies. When this input is enabled, signing settings and private-seed environment
variables cannot be overridden through `additional_env` or ECS canary overrides.

ECS injects `HONUA_TRANSCRIPT_SIGNING_KEY` through native task secrets and renders
`StudioAiProxy__TranscriptSigning__PrivateKeyReference=env://HONUA_TRANSCRIPT_SIGNING_KEY`.
An explicit version uses the native `ARN:::version-id` selector. Only the task
execution role receives the exact secret-read and optional decrypt grant; the
serving task role receives no signer read grant. Stable and canary tasks use the
same configured identity.

Lambda renders the exact full-ARN runtime reference
`aws:secretsmanager:<secret-arn>?versionId=<version-id>` (without the query when
unpinned) and grants only the HTTP function role access to that secret and optional
KMS key. Its environment contains the reference, never the seed. Event-only
functions omit the signer settings and receive no signer grant. The existing
4 KiB environment precondition remains mandatory: a larger configured profile
must be reduced or redesigned explicitly before deployment, never bypassed.

The `aws-cert` preview execution role and its permissions boundary receive the
same exact runtime-only signer grant. The certification runner's existing secret
capture set, read permissions, deployment contract and operations contract do not
include the signer or its KMS key. A signer reused as a runner-captured secret is
rejected. Preview runtime read access does not authorize runner capture or expose
a private key to release artifacts.

## Server and public-manifest handoff

Lambda requires a server image containing the supported-reference validator
correction tracked by [honua-server#6292](https://github.com/honua-io/honua-server/issues/6292).
Older validators reject the supported `aws:secretsmanager:` syntax because it does
not contain `://`. This module does not evade that validation by placing the seed
inline. Select an immutable image containing the delivered correction before
using Lambda signing; this Terraform change alone proves no running deployment.

The operator independently approves the matching public Ed25519 verification
manifest and its key ID before certification. The server publishes that public
manifest as `transcriptSigning` in its Studio AI capabilities response. The
release verifier checks the candidate's manifest against the protected
`TERMINAL_MODEL_SIGNING_MANIFEST_SHA256` input; this digest does not configure a
private signer. Its current canonicalization is the UTF-8 encoding of Python
`json.dumps(manifest, sort_keys=True, separators=(",", ":"))`, SHA-256 in lowercase
hex. Approve the public document independently rather than automatically trusting
a freshly fetched candidate document as the verification root.

For rotation, create and approve the new seed/version and corresponding public
manifest outside Terraform, update the protected key ID/version and manifest
digest together, and review the saved plan. ECS needs a new task deployment to
inject the selected version; Lambda must use the updated reference. Retain prior
public verification material for historical receipts and respect the server's
public-key validity/revocation policy. This initial input configures one active
signer; it does not configure an overlap-key window or claim zero-downtime key
rotation.

Mocked Terraform tests prove rendered references, exact IAM scope, root wiring,
negative inputs and environment limits. They do not qualify a model invocation,
secret payload, signature, AWS endpoint or release candidate. The genuine-model
producer must still run against the deployed immutable candidate and emit its
real signed receipt under the existing release gates.
