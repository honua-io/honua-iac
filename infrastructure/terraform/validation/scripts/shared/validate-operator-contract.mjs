#!/usr/bin/env node
// Validator for honua.operator-contract/v1 documents.
//
// Reads a `terraform output -json` document (or a bare contract envelope),
// checks it against infrastructure/terraform/contracts/operator-contract.v1.schema.json,
// then applies the semantic rules the schema alone cannot express: canonical
// byte reproducibility, contract-digest recomputation, cross-contract identity
// agreement, immutable-pin enforcement, and secret-value leakage.
//
// Zero dependencies on purpose. This repo has no root package manager, and the
// same corpus has to be checkable from honua-devops and honua-release without
// pulling a validator toolchain along with it.
//
// Usage:
//   validate-operator-contract.mjs [options] <file|->
//
// Options:
//   --schema <path>       Schema file. Defaults to the checked-in v1 schema.
//   --require-qualified   Fail when identity.status is not "qualified".
//                         This is the certified-consumer posture.
//   --expect-code <CODE>  Require that CODE is among the findings (and that
//                         the document is invalid). Used by the fixture suite.
//   --expect-valid        Require that the document has no findings.
//   --json                Emit findings as JSON.
//   --quiet               Suppress the human-readable report.
//
// Exit codes: 0 = expectations met, 1 = expectations not met, 2 = usage error.

import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, '../../../../..');
const DEFAULT_SCHEMA = resolve(
  REPO_ROOT,
  'infrastructure/terraform/contracts/operator-contract.v1.schema.json',
);

const SCHEMA_VERSION = 'honua.operator-contract/v1';
const CONTRACT_KEYS = ['deployment_contract', 'validation_contract', 'operations_contract'];

// --------------------------------------------------------------------------
// Canonical bytes
// --------------------------------------------------------------------------
//
// The canonical form is RFC 8785 key ordering and compact separators, plus the
// three HTML escapes Terraform's jsonencode() emits (`<`, `>`, `&`). Within the
// value space the contract allows -- printable-ASCII object keys, safe
// integers, no control characters -- this reproduces `jsonencode()` byte for
// byte, which is what makes the digest checkable on both sides of the handoff.
// Anything outside that value space is rejected rather than silently hashed
// into a value the producer and consumer would disagree about.

class CanonicalizationError extends Error {
  constructor(message, path) {
    super(message);
    this.path = path;
  }
}

const CONTROL_CHARS = /[\u0000-\u001f\u007f]/;
const LINE_SEPARATORS = /[\u2028\u2029]/;
const ASCII_PRINTABLE = /^[\x20-\x7e]+$/;

function canonicalString(value, path) {
  if (CONTROL_CHARS.test(value)) {
    throw new CanonicalizationError('string contains a control character', path);
  }
  if (LINE_SEPARATORS.test(value)) {
    throw new CanonicalizationError('string contains U+2028 or U+2029', path);
  }
  return JSON.stringify(value)
    .replaceAll('<', '\\u003c')
    .replaceAll('>', '\\u003e')
    .replaceAll('&', '\\u0026');
}

function canonicalize(value, path = '$') {
  if (value === null) return 'null';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') {
    if (!Number.isSafeInteger(value)) {
      throw new CanonicalizationError(
        'number is not a safe integer; the contract value space is integers only',
        path,
      );
    }
    return String(value);
  }
  if (typeof value === 'string') return canonicalString(value, path);
  if (Array.isArray(value)) {
    return `[${value.map((item, i) => canonicalize(item, `${path}[${i}]`)).join(',')}]`;
  }
  if (typeof value === 'object') {
    const keys = Object.keys(value).sort();
    for (const key of keys) {
      if (!ASCII_PRINTABLE.test(key)) {
        throw new CanonicalizationError(
          `object key ${JSON.stringify(key)} is not printable ASCII`,
          path,
        );
      }
    }
    const body = keys
      .map((key) => `${canonicalString(key, path)}:${canonicalize(value[key], `${path}.${key}`)}`)
      .join(',');
    return `{${body}}`;
  }
  throw new CanonicalizationError(`unsupported value type ${typeof value}`, path);
}

function sha256Hex(text) {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

// --------------------------------------------------------------------------
// Minimal JSON Schema 2020-12 evaluator (the subset the contract schema uses)
// --------------------------------------------------------------------------

function typeOf(value) {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  if (Number.isInteger(value)) return 'integer';
  if (typeof value === 'number') return 'number';
  return typeof value;
}

function typeMatches(value, expected) {
  const actual = typeOf(value);
  if (expected === 'number') return actual === 'number' || actual === 'integer';
  return actual === expected;
}

function deepEqual(a, b) {
  if (a === b) return true;
  if (typeOf(a) !== typeOf(b)) return false;
  if (Array.isArray(a)) {
    return a.length === b.length && a.every((item, i) => deepEqual(item, b[i]));
  }
  if (a && typeof a === 'object') {
    const ka = Object.keys(a).sort();
    const kb = Object.keys(b).sort();
    return deepEqual(ka, kb) && ka.every((k) => deepEqual(a[k], b[k]));
  }
  return false;
}

class SchemaValidator {
  constructor(root) {
    this.root = root;
  }

  resolveRef(ref) {
    if (!ref.startsWith('#/')) {
      throw new Error(`unsupported $ref (local refs only): ${ref}`);
    }
    let node = this.root;
    for (const rawPart of ref.slice(2).split('/')) {
      const part = rawPart.replaceAll('~1', '/').replaceAll('~0', '~');
      node = node?.[part];
      if (node === undefined) throw new Error(`unresolvable $ref: ${ref}`);
    }
    return node;
  }

  validate(value, schema = this.root, path = '$', errors = []) {
    if (schema === true || schema === undefined) return errors;
    if (schema === false) {
      errors.push({ path, message: 'value is not allowed here' });
      return errors;
    }
    if (schema.$ref) {
      this.validate(value, this.resolveRef(schema.$ref), path, errors);
    }

    if (schema.type !== undefined) {
      const expected = Array.isArray(schema.type) ? schema.type : [schema.type];
      if (!expected.some((t) => typeMatches(value, t))) {
        errors.push({
          path,
          message: `expected type ${expected.join(' or ')} but found ${typeOf(value)}`,
        });
        return errors;
      }
    }

    if (schema.const !== undefined && !deepEqual(value, schema.const)) {
      errors.push({ path, message: `expected the constant ${JSON.stringify(schema.const)}` });
    }

    if (schema.enum !== undefined && !schema.enum.some((c) => deepEqual(value, c))) {
      errors.push({ path, message: `value is not one of ${JSON.stringify(schema.enum)}` });
    }

    if (typeof value === 'string') {
      if (schema.pattern !== undefined && !new RegExp(schema.pattern, 'u').test(value)) {
        errors.push({ path, message: `does not match ${schema.pattern}` });
      }
      if (schema.minLength !== undefined && value.length < schema.minLength) {
        errors.push({ path, message: `shorter than minLength ${schema.minLength}` });
      }
    }

    if (typeof value === 'number') {
      if (schema.minimum !== undefined && value < schema.minimum) {
        errors.push({ path, message: `below minimum ${schema.minimum}` });
      }
      if (schema.maximum !== undefined && value > schema.maximum) {
        errors.push({ path, message: `above maximum ${schema.maximum}` });
      }
    }

    if (Array.isArray(value)) {
      if (schema.items !== undefined) {
        value.forEach((item, i) => this.validate(item, schema.items, `${path}[${i}]`, errors));
      }
      if (schema.minItems !== undefined && value.length < schema.minItems) {
        errors.push({ path, message: `fewer than minItems ${schema.minItems}` });
      }
    }

    if (value && typeof value === 'object' && !Array.isArray(value)) {
      for (const required of schema.required ?? []) {
        if (!Object.hasOwn(value, required)) {
          errors.push({ path: `${path}.${required}`, message: 'required property is missing' });
        }
      }
      const properties = schema.properties ?? {};
      for (const [key, propSchema] of Object.entries(properties)) {
        if (Object.hasOwn(value, key)) {
          this.validate(value[key], propSchema, `${path}.${key}`, errors);
        }
      }
      if (schema.propertyNames !== undefined) {
        for (const key of Object.keys(value)) {
          this.validate(key, schema.propertyNames, `${path}.${key} (property name)`, errors);
        }
      }
      if (schema.additionalProperties !== undefined) {
        for (const key of Object.keys(value)) {
          if (Object.hasOwn(properties, key)) continue;
          if (schema.additionalProperties === false) {
            errors.push({ path: `${path}.${key}`, message: 'property is not allowed by the schema' });
          } else {
            this.validate(value[key], schema.additionalProperties, `${path}.${key}`, errors);
          }
        }
      }
    }

    for (const sub of schema.allOf ?? []) this.validate(value, sub, path, errors);

    if (schema.anyOf !== undefined) {
      const ok = schema.anyOf.some((sub) => this.validate(value, sub, path, []).length === 0);
      if (!ok) errors.push({ path, message: 'value does not satisfy any anyOf branch' });
    }

    if (schema.oneOf !== undefined) {
      const matches = schema.oneOf.filter(
        (sub) => this.validate(value, sub, path, []).length === 0,
      ).length;
      if (matches !== 1) {
        errors.push({ path, message: `value matches ${matches} oneOf branches, expected exactly 1` });
      }
    }

    if (schema.not !== undefined && this.validate(value, schema.not, path, []).length === 0) {
      errors.push({ path, message: 'value must not match the "not" schema' });
    }

    if (schema.if !== undefined) {
      const branch =
        this.validate(value, schema.if, path, []).length === 0 ? schema.then : schema.else;
      if (branch !== undefined) this.validate(value, branch, path, errors);
    }

    return errors;
  }
}

// --------------------------------------------------------------------------
// Semantic rules
// --------------------------------------------------------------------------

const SECRET_VALUE_PATTERNS = [
  [/\b[a-z][a-z0-9+.-]*:\/\/[^\s/@:]+:[^\s/@]+@/i, 'URI with embedded credentials'],
  [/(?:^|[;\s,{"])(?:password|pwd|passwd)\s*=\s*\S/i, 'key=value credential pair'],
  [/\bAKIA[0-9A-Z]{16}\b/, 'AWS access key id'],
  [/\bASIA[0-9A-Z]{16}\b/, 'AWS temporary access key id'],
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----/, 'PEM private key'],
  [/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\./, 'JWT'],
  [/\bgh[pousr]_[A-Za-z0-9]{20,}\b/, 'GitHub token'],
  [/\bgithub_pat_[A-Za-z0-9_]{20,}\b/, 'GitHub fine-grained token'],
  [/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/, 'Slack token'],
  [/\bsk-[A-Za-z0-9]{24,}\b/, 'provider API key'],
  [/\bAIza[0-9A-Za-z_-]{35}\b/, 'Google API key'],
  [/\bSharedAccessKey=\S/i, 'Azure shared access key'],
  [/\bAccountKey=\S/i, 'Azure storage account key'],
];

// Keys whose value is a locator by construction, so the credential-shaped-name
// rule below does not apply to them.
const LOCATOR_KEY = /(_ref|_refs|_arn|_digest|_id|_name|_path|_url|_job|_group|_policy|_mode|_prefix|_source|_root|_version|_lineage)$|^(id|kind|provider|references|managed_by|status|profile|transport)$/;
const CREDENTIAL_KEY = /passwo?rd|secret|token|credential|api_?key|connection_string|conn_str|master_key/i;
const SECRET_REFERENCE_ARN = /^arn:aws[a-z0-9-]*:(secretsmanager|ssm|kms):[a-z0-9-]+:[0-9]{12}:.+$/;

function walk(value, path, visit) {
  visit(value, path);
  if (Array.isArray(value)) {
    value.forEach((item, i) => walk(item, `${path}[${i}]`, visit));
  } else if (value && typeof value === 'object') {
    for (const [key, child] of Object.entries(value)) {
      visit(child, `${path}.${key}`, key);
      walk(child, `${path}.${key}`, visit);
    }
  }
}

function scanForSecretValues(doc, findings) {
  const seen = new Set();
  walk(doc, '$', (value, path, key) => {
    if (typeof value !== 'string') return;
    const marker = `${path}::${value}`;
    if (seen.has(marker)) return;
    seen.add(marker);

    for (const [pattern, label] of SECRET_VALUE_PATTERNS) {
      if (pattern.test(value)) {
        findings.push({
          code: 'E_SECRET_VALUE',
          path,
          message: `looks like a secret value (${label}); the contract carries references only`,
        });
        return;
      }
    }

    if (key && CREDENTIAL_KEY.test(key) && !LOCATOR_KEY.test(key)) {
      if (!SECRET_REFERENCE_ARN.test(value)) {
        findings.push({
          code: 'E_SECRET_VALUE',
          path,
          message: `credential-shaped key holds ${JSON.stringify(value)}, which is not a Secrets Manager, SSM, or KMS reference`,
        });
      }
    }
  });
}

function stripContractDigest(contract) {
  const clone = structuredClone(contract);
  if (clone && typeof clone === 'object' && clone.identity) {
    delete clone.identity.contract_digest;
  }
  return clone;
}

function checkDigest(envelope, findings) {
  const digestInput = {
    schema_version: SCHEMA_VERSION,
    deployment_contract: stripContractDigest(envelope.deployment_contract),
    validation_contract: stripContractDigest(envelope.validation_contract),
    operations_contract: stripContractDigest(envelope.operations_contract),
  };

  let bytes;
  try {
    bytes = canonicalize(digestInput);
  } catch (error) {
    if (error instanceof CanonicalizationError) {
      findings.push({
        code: 'E_CANONICALIZATION',
        path: error.path,
        message: `${error.message}; the contract digest cannot be reproduced`,
      });
      return null;
    }
    throw error;
  }

  const expected = sha256Hex(bytes);
  for (const key of CONTRACT_KEYS) {
    const claimed = envelope[key]?.identity?.contract_digest;
    if (claimed === null || claimed === undefined) continue;
    if (claimed !== expected) {
      findings.push({
        code: 'E_DIGEST_MISMATCH',
        path: `$.${key}.identity.contract_digest`,
        message: `claims ${claimed} but the canonical bytes digest to ${expected}`,
      });
    }
  }
  return expected;
}

function checkIdentityAgreement(envelope, findings) {
  const [first, ...rest] = CONTRACT_KEYS;
  const reference = envelope[first]?.identity;
  if (!reference) return;
  let referenceBytes;
  try {
    referenceBytes = canonicalize(reference);
  } catch {
    return;
  }
  for (const key of rest) {
    const other = envelope[key]?.identity;
    let otherBytes;
    try {
      otherBytes = canonicalize(other);
    } catch {
      continue;
    }
    if (otherBytes !== referenceBytes) {
      findings.push({
        code: 'E_IDENTITY_MISMATCH',
        path: `$.${key}.identity`,
        message: `identity block differs from $.${first}.identity; all three contracts must describe the same deployment`,
      });
    }
  }
}

function checkImmutablePins(envelope, findings) {
  const identity = envelope.deployment_contract?.identity;
  if (!identity) return;

  const { image_reference: reference, image_digest: digest } = identity;
  if (reference && digest && !reference.endsWith(`@${digest}`)) {
    findings.push({
      code: 'E_MUTABLE_PIN',
      path: '$.deployment_contract.identity.image_reference',
      message: `${reference} does not end with @${digest}; the reference and the digest describe different images`,
    });
  }
  if (reference && !reference.includes('@sha256:')) {
    findings.push({
      code: 'E_MUTABLE_PIN',
      path: '$.deployment_contract.identity.image_reference',
      message: `${reference} is not digest-pinned; a tag is mutable and cannot qualify a release deployment`,
    });
  }

  const artifacts = envelope.validation_contract?.artifacts;
  if (artifacts) {
    if (artifacts.image_reference !== undefined && artifacts.image_reference !== reference) {
      findings.push({
        code: 'E_MUTABLE_PIN',
        path: '$.validation_contract.artifacts.image_reference',
        message: 'disagrees with identity.image_reference',
      });
    }
    if (artifacts.image_digest !== undefined && artifacts.image_digest !== digest) {
      findings.push({
        code: 'E_MUTABLE_PIN',
        path: '$.validation_contract.artifacts.image_digest',
        message: 'disagrees with identity.image_digest',
      });
    }
  }
}

function checkPlatformAgreement(envelope, findings) {
  const identity = envelope.deployment_contract?.identity;
  const platform = identity?.platform;
  const stack = envelope.deployment_contract?.stack;
  const selectors = envelope.validation_contract?.selectors;
  if (!platform || !stack) return;

  const claims = [
    ['region', platform.region, stack.region, '$.deployment_contract.stack.region'],
    ['account_id', platform.account_id, stack.account_id, '$.deployment_contract.stack.account_id'],
  ];
  if (selectors) {
    claims.push(
      ['region', platform.region, selectors.region, '$.validation_contract.selectors.region'],
      [
        'account_id',
        platform.account_id,
        selectors.account_id,
        '$.validation_contract.selectors.account_id',
      ],
    );
  }
  for (const [field, expected, actual, path] of claims) {
    if (actual !== expected) {
      findings.push({
        code: 'E_ACCOUNT_MISMATCH',
        path,
        message: `${field} is ${JSON.stringify(actual)} but identity.platform.${field} is ${JSON.stringify(expected)}`,
      });
    }
  }

  const cluster = envelope.deployment_contract?.workload?.cluster_id;
  if (cluster && platform.account_id && !cluster.includes(`:${platform.account_id}:`)) {
    findings.push({
      code: 'E_ACCOUNT_MISMATCH',
      path: '$.deployment_contract.workload.cluster_id',
      message: `ARN does not belong to account ${platform.account_id}`,
    });
  }
}

function checkEndpointAgreement(envelope, findings) {
  const base = envelope.deployment_contract?.endpoints?.public_base_url;
  if (!base) return;

  const ingress = envelope.deployment_contract?.dependencies?.ingress?.endpoint;
  if (ingress && ingress !== base) {
    findings.push({
      code: 'E_ENDPOINT_MISMATCH',
      path: '$.deployment_contract.dependencies.ingress.endpoint',
      message: `is ${ingress} but the public base URL is ${base}`,
    });
  }

  const tests = envelope.validation_contract?.tests ?? {};
  for (const [name, url] of Object.entries(tests)) {
    if (typeof url !== 'string') continue;
    if (!url.startsWith(`${base}/`)) {
      findings.push({
        code: 'E_ENDPOINT_MISMATCH',
        path: `$.validation_contract.tests.${name}`,
        message: `${url} is not under the deployment's public base URL ${base}`,
      });
    }
  }
}

function checkSecretRefAgreement(envelope, findings) {
  const refs = envelope.deployment_contract?.secret_refs ?? {};
  const registry = envelope.operations_contract?.secrets?.references ?? {};
  for (const [name, arn] of Object.entries(refs)) {
    const registered = registry[name];
    if (!registered) {
      findings.push({
        code: 'E_MISSING_FIELD',
        path: `$.operations_contract.secrets.references.${name}`,
        message: `deployment_contract.secret_refs.${name} has no entry in the authoritative secret registry`,
      });
      continue;
    }
    if (registered.id !== arn) {
      findings.push({
        code: 'E_SECRET_REF_MISMATCH',
        path: `$.operations_contract.secrets.references.${name}.id`,
        message: `is ${registered.id} but deployment_contract.secret_refs.${name} is ${arn}`,
      });
    }
  }
}

function checkQualified(envelope, findings) {
  const status = envelope.deployment_contract?.identity?.status;
  if (status !== 'qualified') {
    findings.push({
      code: 'E_UNQUALIFIED',
      path: '$.deployment_contract.identity.status',
      message: `status is ${JSON.stringify(status)}; a certified lane requires "qualified"`,
    });
  }
}

// --------------------------------------------------------------------------
// Document normalization
// --------------------------------------------------------------------------

function isTerraformOutputWrapper(value) {
  return (
    value &&
    typeof value === 'object' &&
    !Array.isArray(value) &&
    Object.hasOwn(value, 'value') &&
    Object.hasOwn(value, 'sensitive')
  );
}

function normalize(raw, findings) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    findings.push({ code: 'E_MISSING_FIELD', path: '$', message: 'document is not a JSON object' });
    return null;
  }

  const envelope = {};
  for (const key of CONTRACT_KEYS) {
    if (!Object.hasOwn(raw, key)) {
      findings.push({
        code: 'E_MISSING_FIELD',
        path: `$.${key}`,
        message: 'contract output is missing from the document',
      });
      continue;
    }
    const member = raw[key];
    if (isTerraformOutputWrapper(member)) {
      if (member.sensitive === true) {
        findings.push({
          code: 'E_SECRET_VALUE',
          path: `$.${key}`,
          message:
            'output is marked sensitive; a contract that carries only references must never be sensitive',
        });
      }
      envelope[key] = member.value;
    } else {
      envelope[key] = member;
    }
  }

  if (Object.keys(envelope).length !== CONTRACT_KEYS.length) return null;

  const declared = Object.hasOwn(raw, 'schema_version')
    ? isTerraformOutputWrapper(raw.schema_version)
      ? raw.schema_version.value
      : raw.schema_version
    : envelope.deployment_contract?.schema_version;

  envelope.schema_version = declared;
  return envelope;
}

function checkSchemaVersion(envelope, findings) {
  const versions = new Set([envelope.schema_version]);
  for (const key of CONTRACT_KEYS) versions.add(envelope[key]?.schema_version);
  for (const version of versions) {
    if (version !== SCHEMA_VERSION) {
      findings.push({
        code: 'E_UNKNOWN_VERSION',
        path: '$.schema_version',
        message: `schema version ${JSON.stringify(version ?? null)} is not ${SCHEMA_VERSION}; fail closed`,
      });
      return false;
    }
  }
  return true;
}

// --------------------------------------------------------------------------
// Entry point
// --------------------------------------------------------------------------

export function validateDocument(raw, { schema, requireQualified = false } = {}) {
  const findings = [];
  const envelope = normalize(raw, findings);
  if (!envelope) return findings;

  const versionOk = checkSchemaVersion(envelope, findings);

  if (versionOk) {
    const validator = new SchemaValidator(schema);
    const schemaErrors = validator.validate({
      schema_version: envelope.schema_version,
      deployment_contract: envelope.deployment_contract,
      validation_contract: envelope.validation_contract,
      operations_contract: envelope.operations_contract,
    });
    for (const error of schemaErrors) {
      findings.push({
        code: error.message === 'required property is missing' ? 'E_MISSING_FIELD' : 'E_SCHEMA',
        path: error.path,
        message: error.message,
      });
    }
  }

  scanForSecretValues(envelope, findings);
  checkIdentityAgreement(envelope, findings);
  checkDigest(envelope, findings);
  checkImmutablePins(envelope, findings);
  checkPlatformAgreement(envelope, findings);
  checkEndpointAgreement(envelope, findings);
  checkSecretRefAgreement(envelope, findings);
  if (requireQualified) checkQualified(envelope, findings);

  return findings;
}

function parseArgs(argv) {
  const options = {
    schema: DEFAULT_SCHEMA,
    requireQualified: false,
    expectCode: null,
    expectValid: false,
    json: false,
    quiet: false,
    input: null,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case '--schema':
        options.schema = argv[++i];
        break;
      case '--require-qualified':
        options.requireQualified = true;
        break;
      case '--expect-code':
        options.expectCode = argv[++i];
        break;
      case '--expect-valid':
        options.expectValid = true;
        break;
      case '--json':
        options.json = true;
        break;
      case '--quiet':
        options.quiet = true;
        break;
      case '-h':
      case '--help':
        options.help = true;
        break;
      default:
        if (arg.startsWith('--')) {
          throw new Error(`unknown option: ${arg}`);
        }
        options.input = arg;
    }
  }
  return options;
}

function main(argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    process.stderr.write(`[ERROR] ${error.message}\n`);
    return 2;
  }

  if (options.help || !options.input) {
    process.stderr.write(
      'usage: validate-operator-contract.mjs [--schema PATH] [--require-qualified]\n' +
        '                                     [--expect-code CODE] [--expect-valid]\n' +
        '                                     [--json] [--quiet] <file|->\n',
    );
    return options.help ? 0 : 2;
  }

  const source = options.input === '-' ? 0 : options.input;
  let raw;
  try {
    raw = JSON.parse(readFileSync(source, 'utf8'));
  } catch (error) {
    process.stderr.write(`[ERROR] could not read JSON from ${options.input}: ${error.message}\n`);
    return 2;
  }

  let schema;
  try {
    schema = JSON.parse(readFileSync(options.schema, 'utf8'));
  } catch (error) {
    process.stderr.write(`[ERROR] could not read schema ${options.schema}: ${error.message}\n`);
    return 2;
  }

  const findings = validateDocument(raw, {
    schema,
    requireQualified: options.requireQualified,
  });

  if (options.json) {
    process.stdout.write(`${JSON.stringify({ input: options.input, findings }, null, 2)}\n`);
  } else if (!options.quiet) {
    if (findings.length === 0) {
      process.stdout.write(`[OK] ${options.input}: honua.operator-contract/v1 is valid\n`);
    } else {
      process.stdout.write(`[FAIL] ${options.input}: ${findings.length} finding(s)\n`);
      for (const finding of findings) {
        process.stdout.write(`  ${finding.code} ${finding.path}: ${finding.message}\n`);
      }
    }
  }

  if (options.expectValid) {
    return findings.length === 0 ? 0 : 1;
  }
  if (options.expectCode) {
    const matched = findings.some((finding) => finding.code === options.expectCode);
    if (!matched && !options.quiet) {
      process.stdout.write(
        `[FAIL] expected finding ${options.expectCode} was not reported\n`,
      );
    }
    return matched ? 0 : 1;
  }
  return findings.length === 0 ? 0 : 1;
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  process.exit(main(process.argv.slice(2)));
}
