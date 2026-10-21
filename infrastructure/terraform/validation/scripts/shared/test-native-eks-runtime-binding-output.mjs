#!/usr/bin/env node
// Validate the exact mocked native EKS Terraform output, not a copied fixture.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { SchemaValidator } from './validate-operator-contract.mjs';

const schema = JSON.parse(readFileSync(new URL('../../../contracts/runtime-binding.v1.schema.json', import.meta.url)));
const validator = new SchemaValidator(schema);
const events = readFileSync(process.argv[2], 'utf8').trim().split('\n').map((line) => JSON.parse(line));
if (process.argv[3] === '--diagnostics-only') {
  // Terraform's verbose JSON includes planned state. Emit only bounded test
  // status and diagnostic titles when a mocked test fails.
  const safe = (value) => String(value ?? '').replace(/[\x00-\x1f\x7f]+/g, ' ').slice(0, 240);
  const runs = events.filter((item) => item.type === 'test_run');
  runs.sort((a, b) => Number(['fail', 'error'].includes(b.test_run?.status)) - Number(['fail', 'error'].includes(a.test_run?.status)));
  for (const event of runs.slice(0, 16)) {
    console.error(`Terraform test ${safe(event['@testrun'])}: ${safe(event.test_run?.status)}`);
  }
  const diagnostics = events.filter((item) => item.type === 'diagnostic');
  diagnostics.sort((a, b) => Number(b.diagnostic?.severity === 'error') - Number(a.diagnostic?.severity === 'error'));
  for (const event of diagnostics.slice(0, 12)) {
    const range = event.diagnostic?.range;
    const location = range?.filename && Number.isSafeInteger(range.start?.line)
      ? ` (${safe(range.filename)}:${range.start.line})` : '';
    console.error(`Terraform ${safe(event.diagnostic?.severity)}: ${safe(event.diagnostic?.summary)}${location}`);
  }
  const result = events.findLast((event) => event.type === 'test_summary')?.test_summary;
  if (result) console.error(`Terraform summary: ${result.passed} passed, ${result.failed} failed, ${result.errored} errored`);
  process.exit(0);
}
const summary = events.find((event) => event.type === 'test_summary')?.test_summary;
assert.equal(summary?.status, 'pass', 'all native EKS Terraform tests must pass');
assert.equal(summary.passed, 8, 'every native EKS scenario must run');

for (const name of ['native_install_projects_configured_resources', 'external_dns_is_unqualified']) {
  const states = events.filter((event) => event.type === 'test_state' && event['@testrun'] === name);
  assert.equal(states.length, 1, `${name} must emit its actual Terraform state`);
  const output = states[0].test_state.outputs.runtime_binding_contract;
  assert.equal(output?.sensitive, false, `${name}: binding must contain no secret values`);
  const binding = output.value;
  assert.deepEqual(validator.validate(binding), [], `${name}: binding must satisfy the strict v1 schema`);
  const identity = binding.resourceIdentity;
  assert.notEqual(identity.serverRoleArn, identity.gpRoleArn, 'server and GP roles must remain distinct');
  assert.notEqual(identity.serverPodIdentityAssociationId, identity.gpPodIdentityAssociationId,
    'server and GP pod identity associations must remain distinct');

  for (const [field, invalid] of [
    ['certificateArn', 'not-an-acm-arn'],
    ['serverRoleArn', 'not-an-iam-arn'],
    ['dbConnectionSecretArn', 'literal-secret-value'],
    ['serverPodIdentityAssociationId', 'wrong-association'],
  ]) {
    const changed = structuredClone(binding);
    changed.resourceIdentity[field] = invalid;
    assert.notDeepEqual(validator.validate(changed), [], `${name}: ${field} must reject malformed identity`);
  }
  const extra = structuredClone(binding);
  extra.resourceIdentity.secretValue = 'must-not-be-projected';
  assert.notDeepEqual(validator.validate(extra), [], `${name}: arbitrary fields must remain forbidden`);
}
console.log('PASS: both native EKS Terraform outputs satisfy strict runtime binding identity; malformed identity refused');
