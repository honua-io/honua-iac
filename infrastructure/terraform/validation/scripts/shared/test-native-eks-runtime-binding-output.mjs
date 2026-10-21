#!/usr/bin/env node
// Validate the exact mocked native EKS Terraform output, not a copied fixture.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { SchemaValidator } from './validate-operator-contract.mjs';

const schema = JSON.parse(readFileSync(new URL('../../../contracts/runtime-binding.v1.schema.json', import.meta.url)));
const validator = new SchemaValidator(schema);
const events = readFileSync(process.argv[2], 'utf8').trim().split('\n').map((line) => JSON.parse(line));
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
