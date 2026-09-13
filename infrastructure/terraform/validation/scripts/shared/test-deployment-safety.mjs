#!/usr/bin/env node
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { validateDocument } from './validate-operator-contract.mjs';

const schema = JSON.parse(readFileSync(new URL('../../../contracts/operator-contract.v1.schema.json', import.meta.url)));
const fixture = JSON.parse(readFileSync(new URL('../../../contracts/fixtures/valid-aws-ecs-native-safety.json', import.meta.url)));
const keys = ['deployment_contract', 'validation_contract', 'operations_contract'];
const envelope = Object.fromEntries(keys.map(key => [key, fixture[key].value]));
const canonical = value => Array.isArray(value) ? value.map(canonical) :
  value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
function mutated(change) {
  const copy = structuredClone(envelope);
  change(copy.operations_contract.resilience.protection_profile.execution, copy);
  for (const key of keys) delete copy[key].identity.contract_digest;
  const bytes = JSON.stringify(canonical({ schema_version: 'honua.operator-contract/v1', ...copy }))
    .replaceAll('<', '\\u003c').replaceAll('>', '\\u003e').replaceAll('&', '\\u0026');
  const digest = createHash('sha256').update(bytes).digest('hex');
  for (const key of keys) copy[key].identity.contract_digest = digest;
  return copy;
}
function rejected(name, change, code = 'E_PROTECTION_PROFILE') {
  test(name, () => {
    const findings = validateDocument(mutated(change), { schema });
    assert.ok(findings.some(f => f.code === code), JSON.stringify(findings));
    assert.ok(!findings.some(f => f.code === 'E_DIGEST_MISMATCH'), 'negative fixture must retain a valid digest');
  });
}
test('native handoff validates with an independent functional expectation', () => {
  assert.deepEqual(validateDocument(fixture, { schema, requireQualified: true }), []);
  const execution = envelope.operations_contract.resilience.protection_profile.execution;
  assert.equal(createHash('sha256').update('abc').digest('hex'), execution.parameters['telemetry.golden_query.expected_sha256']);
  assert.equal(execution.status, 'configured-unverified');
});
rejected('reject substituted target', execution => { execution.target_id = 'another-target'; });
rejected('reject substituted AWS region', execution => { execution.parameters['aws.region'] = 'us-west-2'; });
rejected('reject missing installed shared storage', (_, doc) => { doc.deployment_contract.dependencies.object_storage.enabled = false; });
rejected('reject missing installed Redis', (_, doc) => { doc.deployment_contract.dependencies.cache.enabled = false; });
rejected('reject identical stable/candidate groups', execution => {
  execution.parameters['aws.alb.stable_target_group_arn'] = execution.parameters['aws.alb.canary_target_group_arn'];
});
for (const [key, max] of Object.entries({
  'deployment.protection.observation_window_seconds': 86400,
  'deployment.rollback.observation_timeout_seconds': 1800,
  'telemetry.warmup_seconds': 21600,
  'telemetry.evidence_grace_seconds': 3600,
  'telemetry.max_staleness_seconds': 3600,
  'telemetry.exposure_deadline_seconds': 7200,
})) {
  for (const value of ['0', '1.5', String(max + 1)]) {
    rejected(`reject ${key}=${value}`, execution => { execution.parameters[key] = value; });
  }
}
rejected('reject missing functional expectation', execution => { delete execution.parameters['telemetry.golden_query.expected_sha256']; }, 'E_MISSING_FIELD');
rejected('reject missing metrics connection', execution => { delete execution.parameters['telemetry.connection']; }, 'E_MISSING_FIELD');
rejected('reject unsupported parameter instead of ignoring it', execution => { execution.parameters['telemetry.typo'] = 'true'; }, 'E_SCHEMA');
rejected('reject Terraform-only verified recovery claim', execution => { execution.status = 'protected'; }, 'E_SCHEMA');
