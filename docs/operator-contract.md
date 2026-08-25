# Honua Operator Contract v1

`honua.operator-contract/v1` is the versioned, machine-validated boundary
between the Terraform that provisions a Honua deployment and everything
downstream that has to reason about it: DevOps bootstrap, verification, smoke,
teardown, day-2 operations, and the release candidate receipt.

Before it existed, those consumers assembled endpoint, workload,
secret-reference, rollout, validation, and teardown facts out of ad hoc scalar
Terraform outputs or caller-authored JSON. That handoff was spoofable, it
encouraged scalar scraping, and nothing in it could prove that honua-iac,
honua-helm, honua-devops, honua-server, and the release candidate were talking
about the same deployment.

- Schema: [`infrastructure/terraform/contracts/operator-contract.v1.schema.json`](../infrastructure/terraform/contracts/operator-contract.v1.schema.json)
- Fixtures: [`infrastructure/terraform/contracts/fixtures/`](../infrastructure/terraform/contracts/fixtures/)
- Validator: `infrastructure/terraform/validation/scripts/shared/validate-operator-contract.mjs`
- Reference producer: `infrastructure/terraform/examples/aws/operator-contract.tf`
- Architecture decision: [ADR 0001](adr/0001-terraform-architecture-refactor.md)

## The three outputs

Every certified deployable root emits three Terraform outputs. They are split
by consumer responsibility, not by convenience, so a consumer reads the one
contract it owns rather than filtering a single blob.

| Output | Question it answers | Primary consumer |
| --- | --- | --- |
| `deployment_contract` | What was deployed, and how does traffic reach it? | honua-devops install handoff |
| `validation_contract` | How should a certified lane exercise and tear this down? | honua-devops verification, honua-release smoke/teardown |
| `operations_contract` | What day-2 resources and attachments exist? | honua-devops operations bootstrap, honua-server runtime config |

All three carry the same `schema_version`, a `kind` discriminator, and a
byte-identical `identity` block. A consumer that reads one contract and one
identity block has enough to reject a document that was assembled from parts of
two different deployments.

A convenience `operator_contract` envelope output carries all three. It is
**non-normative**: it exists for humans and for one-shot capture. The three
individual outputs are the contract.

## Immutable identity

The `identity` block is the part that makes a contract admissible as release
evidence. It answers "which candidate, built from which source, running which
bytes, in which account".

| Field | Meaning | Source |
| --- | --- | --- |
| `status` | `qualified` or `unqualified` | derived |
| `contract_digest` | SHA-256 over the canonical contract bytes | derived |
| `candidate_digest` | honua-release candidate identity | release manifest |
| `manifest_digest` | SHA-256 over the release manifest bytes | release manifest |
| `iac_revision` | exact honua-iac commit | caller |
| `iac_root` | repository-relative Terraform root | Terraform |
| `module_source` | repository-relative platform module | Terraform |
| `terraform_version` | Terraform version that produced the plan | caller |
| `provider_lock_digest` | SHA-256 over the root's `.terraform.lock.hcl` | caller |
| `image_reference` | `registry/repository@sha256:<64 hex>` | release manifest |
| `image_digest` | `sha256:<64 hex>` | release manifest |
| `backend_config_digest` | SHA-256 over the backend configuration | governed execution lane |
| `state_lineage` / `state_serial` | Terraform state lineage reference | governed execution lane |
| `workload_identity` | runtime identity the workload assumes | governed execution lane |
| `artifacts[]` | proxy / CLI / MCP pins, each `{name, kind, version, digest}` | release manifest |
| `platform` | `{provider, partition, account_id, region}` | Terraform |

### What Terraform will and will not do

Terraform **projects** immutable identity. It never manufactures it.

- It will not observe or guess a Git revision. `iac_revision` is a caller input.
- It will not resolve a tag to a digest. There is no registry lookup anywhere
  in this path.
- It will not accept a mutable-looking value in a field that means "immutable".

That last rule is enforced in four places, so a mutable pin cannot reach a
consumer by any route:

1. **Variable validation** on `operator_contract_identity` rejects a
   `candidate_digest`, `manifest_digest`, `provider_lock_digest`, or artifact
   digest that is not 64 lowercase hex; an `iac_revision` that is not a full
   Git object id (abbreviated ids, branches, and tags all fail); an
   `image_digest` that is not `sha256:<64 hex>`; and an `image_reference` that
   is not `registry/repository@sha256:<64 hex>`.
2. **Cross-field variable validation** requires `image_reference` to end with
   `@<image_digest>`, so the reference and the digest cannot describe different
   images.
3. **Output preconditions** on `deployment_contract` require that the image
   actually being deployed is digest-pinned, and that it is the same reference
   the contract claims. Supplying an identity while deploying
   `ghcr.io/honua-io/honua:2026.1.0` fails the plan rather than producing a
   contract that lies about what is running.
4. **The validator** re-checks all of the above on the emitted document, plus
   agreement between `identity.image_*` and
   `validation_contract.artifacts.image_*`.

### `qualified` versus `unqualified`

`status` is `qualified` only when every one of `candidate_digest`,
`manifest_digest`, `iac_revision`, `terraform_version`, `provider_lock_digest`,
`image_reference`, `image_digest`, `backend_config_digest`, `state_lineage`,
`state_serial`, and `workload_identity` is present. There is no partial credit:
a missing pin downgrades the whole contract.

`unqualified` is a legitimate shape. It is what a developer gets when they plan
the stack without a release manifest, and it is schema-valid on purpose.
**Certified consumers must reject it.** The validator's `--require-qualified`
flag is that posture, and it is the flag every certified lane should pass.

## Sensitivity rules

The contract carries **references only**.

Permitted: Secrets Manager / SSM / KMS ARNs, resource ARNs and ids, DNS names,
URLs, region and account identifiers, log group names, tag maps, digests,
versions, counts, and booleans.

Forbidden, without exception:

- secret values of any kind — passwords, master keys, API keys, tokens;
- connection strings, including any URI with embedded credentials;
- rendered sensitive environment values;
- Terraform state contents or state-backend credentials;
- routing credentials such as the canary verification header **value**. The
  header *name* is a selector and is in the contract; the value is a bearer
  credential and is deliberately left in the legacy scalar output only.

Two mechanical guards back this up:

- The schema constrains every secret-bearing position to a Secrets Manager,
  SSM, or KMS ARN pattern.
- The validator scans every string in the document for credential shapes
  (credential-bearing URIs, `password=` pairs, AWS access key ids, PEM private
  keys, JWTs, GitHub / Slack / provider API tokens, Azure shared access keys)
  and additionally requires that any credential-shaped key name holds a
  reference ARN. It also rejects any contract output that Terraform marked
  `sensitive`, since a contract of references has no reason to be.

`deployment_contract.dependencies.database.endpoint` is a bare hostname, not a
connection string, and is present so a consumer can bind the workload to the
right database. If it ever contains credentials the leakage scan fails the
document.

### Two secret surfaces, on purpose

- `deployment_contract.secret_refs` is a flat `name -> ARN` map: exactly the
  references an install handoff needs to wire up.
- `operations_contract.secrets.references` is the authoritative typed registry:
  `name -> {kind, provider, id, kms_key_ref, managed_by}`, for day-2 rotation
  and access review.

The validator requires that every name in `secret_refs` exists in the registry
with the same ARN, so the two surfaces cannot drift.

The admin-password secret ARN appears in both: as
`deployment_contract.secret_refs.admin_password` and as
`operations_contract.secrets.references.admin_password`. Both are required by
the schema.

## Canonicalization and the contract digest

`identity.contract_digest` lets a consumer detect substituted contract bytes.
It is only useful if the producer and the consumer agree, byte for byte, on
what they are hashing.

### Canonical form

Canonical bytes are RFC 8785 (JCS) key ordering and separators, plus the three
HTML escapes Terraform's `jsonencode()` emits:

1. Object keys sorted ascending by code point. Contract keys are ASCII, where
   this is identical to a byte-wise sort.
2. No insignificant whitespace: `{"a":1,"b":[2,3]}`.
3. Strings escaped per RFC 8259, with non-ASCII emitted raw as UTF-8, and
   additionally `<` escaped as `\u003c`, `>` as `\u003e`, and `&` as
   `\u0026`.
4. Integers rendered as their shortest decimal form. `null`, `true`, `false`
   literal.

Within the restricted value space below, this is byte-identical to
`jsonencode()`, which is what makes the digest checkable from both sides. The
CI contract test proves that agreement on every run by hashing the same fixture
through Terraform and through the validator and comparing.

### Restricted value space

The digest is only defined over documents that satisfy all of:

- **Integers only.** No floating-point numbers anywhere in the contract. Go and
  JavaScript do not agree on how to render every float, and a contract has no
  need for one.
- **No control characters** (U+0000–U+001F, U+007F) and no U+2028 / U+2029 in
  any string.
- **Printable-ASCII object keys**, including operator-supplied tag keys.

A document outside this space is rejected with `E_CANONICALIZATION` rather than
being hashed into a value the two sides would disagree about.

### Digest input

The digest is computed over an envelope with the digest fields removed, so it
is not self-referential:

```jsonc
{
  "schema_version": "honua.operator-contract/v1",
  "deployment_contract": { /* identity.contract_digest deleted */ },
  "validation_contract": { /* identity.contract_digest deleted */ },
  "operations_contract": { /* identity.contract_digest deleted */ }
}
```

`contract_digest` is the lowercase hex SHA-256 of the canonical bytes of that
envelope, with no algorithm prefix. All three contracts carry the same value.

To verify: delete `identity.contract_digest` from each of the three contract
values, rebuild the envelope above, canonicalize, SHA-256, compare. The
producer computes it as `sha256(jsonencode(<digest input>))`.

## Compatibility policy

`schema_version` is the fully qualified string `honua.operator-contract/v1`. It
is not a bare `v1`, so a consumer in another repository can tell a Honua
operator contract from any other versioned document it handles.

**Fail closed.** A consumer that reads a `schema_version` it does not recognize
— including an absent one — must reject the document. It must not fall back to
legacy scalar outputs, and it must not partially interpret a newer contract.

Within v1:

- **Additive, non-breaking:** a new optional field; a new enum member in a
  field documented as open; a new key in `secret_refs`, `secrets.references`,
  `tags`, or `artifacts`.
- **Breaking, requires v2:** removing a field; renaming a field; narrowing a
  type; changing the meaning of an existing field; changing the digest input or
  the canonical form.

Core objects are `additionalProperties: false`. Platform-specific facts go in
the per-contract `extensions` object, which is deliberately unconstrained.
**An extension may add facts. It may never restate, override, or reinterpret a
core field.** A consumer that ignores `extensions` entirely must still get a
correct reading of the deployment — that is the property that keeps AWS from
being flattened into a least-common-denominator blob when other platforms
arrive.

## Producer and consumer ownership

| Repository | Role | Owns | Must not |
| --- | --- | --- | --- |
| **honua-iac** | Producer (authoritative) | The schema, the canonicalization and digest rules, the fixture corpus, the validator, and the Terraform projection for each certified root. | Guess a revision, resolve a tag to a digest, or emit a secret value. |
| **honua-helm** | Producer (future) | The same three semantic contracts for a certified Helm lane, mapped from chart values and cluster state, using this schema and this digest rule. Chart-specific facts belong in `extensions`. | Redefine core field meanings, or introduce a parallel contract version. |
| **honua-devops** | Consumer (primary) | Deriving the secretless install handoff and the provisioning binding from the exact Terraform output bytes plus verification evidence. Resolving secret references at runtime. | Reconstruct a certified handoff from legacy scalars or caller-authored endpoint/identity JSON; accept an `unqualified` contract. |
| **honua-server** | Consumer | Runtime configuration derived from `operations_contract`: observability attachment, scaling envelope, secret-store binding. | Read the contract as a source of credentials; it holds references only. |
| **honua-release** | Consumer / identity source | Supplying `candidate_digest`, `manifest_digest`, `image_reference`, `image_digest`, and artifact pins from the release manifest; joining `contract_digest` to the provision, handoff-verification, smoke, teardown, and candidate receipt identities. | Accept a contract whose `candidate_digest` does not match the candidate under test, or whose `contract_digest` does not recompute. |

The governed execution lane that owns remote state and deployment identity
supplies `backend_config_digest`, `state_lineage`, `state_serial`, and
`workload_identity`. This contract projects them; it does not implement them.

## Validating a contract

```bash
# Capture and validate a real deployment's contract.
terraform -chdir=infrastructure/terraform/examples/aws output -json > contract.json
./scripts/validate-operator-contract.sh --require-qualified contract.json

# Run the fixture corpus and the negative tests (what CI runs).
./scripts/test-operator-contract.sh
```

The validator accepts a full `terraform output -json` document (extra outputs
are ignored) or a bare `{schema_version, deployment_contract, ...}` envelope.

### Finding codes

| Code | Meaning |
| --- | --- |
| `E_UNKNOWN_VERSION` | `schema_version` is absent or is not `honua.operator-contract/v1`. |
| `E_MISSING_FIELD` | A required field or contract output is absent. |
| `E_SCHEMA` | A field violates the schema (type, pattern, enum, unknown property). |
| `E_MUTABLE_PIN` | An immutable field holds a mutable or mismatched value. |
| `E_SECRET_VALUE` | A secret value, connection string, or credential shape appears where a reference belongs. |
| `E_SECRET_REF_MISMATCH` | `deployment_contract.secret_refs` disagrees with the authoritative registry. |
| `E_DIGEST_MISMATCH` | `contract_digest` does not match the canonical bytes. |
| `E_IDENTITY_MISMATCH` | The three contracts do not carry the same identity block. |
| `E_ACCOUNT_MISMATCH` | Account or region disagree across the contracts, or an ARN belongs to another account. |
| `E_ENDPOINT_MISMATCH` | A test or ingress endpoint is not under the deployment's public base URL. |
| `E_CANONICALIZATION` | The document is outside the value space the digest is defined over. |
| `E_UNQUALIFIED` | `--require-qualified` was requested and `status` is not `qualified`. |

### Fixture corpus

`infrastructure/terraform/contracts/fixtures/` is the shared corpus. Consumer
contract tests in honua-devops and honua-release should run against these exact
bytes.

| Fixture | Expected |
| --- | --- |
| `valid-aws-ecs-small.json` | Valid, and satisfies `--require-qualified`. |
| `valid-aws-ecs-small-unqualified.json` | Schema-valid; rejected by `--require-qualified`. |
| `invalid-missing-required-field.json` | `E_MISSING_FIELD` |
| `invalid-unknown-schema-version.json` | `E_UNKNOWN_VERSION` |
| `invalid-mutable-image-tag.json` | `E_MUTABLE_PIN` |
| `invalid-secret-value-leak.json` | `E_SECRET_VALUE` |
| `invalid-contract-digest-mismatch.json` | `E_DIGEST_MISMATCH` |
| `invalid-account-mismatch.json` | `E_ACCOUNT_MISMATCH` |
| `invalid-endpoint-mismatch.json` | `E_ENDPOINT_MISMATCH` |
| `invalid-identity-mismatch.json` | `E_IDENTITY_MISMATCH` |
| `invalid-secret-ref-mismatch.json` | `E_SECRET_REF_MISMATCH` |

Except for the digest-mismatch case, every negative fixture carries a
*correctly recomputed* digest. A document that hashes correctly but still
violates a semantic rule is precisely the case a naive consumer would wave
through, so that is the case the corpus tests.

Regenerate after a schema change:

```bash
node infrastructure/terraform/contracts/fixtures/make-fixtures.mjs
./scripts/test-operator-contract.sh
```

## Legacy scalar outputs

The scalar outputs in `infrastructure/terraform/examples/aws/outputs.tf`
(`honua_url`, `ecs_cluster_name`, `db_endpoint`, the `control_plane_*` family,
and the rest) are **non-authoritative**. They remain for backward compatibility
with operator scripts and older validation plumbing, and they are marked for
removal.

They carry no schema version, no immutable identity, and no digest, so they
cannot prove that two facts came from the same deployment. New certified
automation must consume the contract outputs and must not reconstruct a handoff
from scalars.

Every output in that file carries the marker `Non-authoritative legacy scalar`
in its description, and `test-operator-contract.sh` fails if one does not. That
check is what prevents a new scalar from quietly becoming a dependency.

The marketplace `install_contract` and `deploy_contract` outputs in
`marketplace.tf` are a separate, still-current surface and are not part of this
deprecation.

## Platform coverage

`examples/aws` (AWS ECS small) is the certified v1 producer for 2026.1. Other
deployable roots still emit legacy scalars only. Each remaining platform needs
its own narrow projection issue against this schema — not a weakening of the
AWS contract to whatever every platform happens to share.
