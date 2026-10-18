#!/usr/bin/env node
// Check the actual mock-applied customer root output against the consumer's
// schema/digest rules. A synthetic JSON fixture cannot prove this projection.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { validateDocument } from './validate-operator-contract.mjs';

const schema = JSON.parse(readFileSync(new URL('../../../contracts/operator-contract.v2.schema.json', import.meta.url)));
const events = readFileSync(process.argv[2], 'utf8').trim().split('\n').map(line => JSON.parse(line));
const summary = events.find(event => event.type === 'test_summary')?.test_summary;
assert.equal(summary?.status, 'pass', 'Terraform root tests must pass');
assert.equal(summary.passed, 8, 'every Lambda producer scenario must run');
const positiveRuns = new Map([
  ['unqualified_development_contract', false],
  ['qualified_lambda_contract', true],
  ['proxy_and_shared_storage_are_real_runtime_dependencies', true],
  ['external_database_is_not_claimed_as_managed', true],
]);
for (const [runName, requireQualified] of positiveRuns) {
  const states = events.filter(event => event.type === 'test_state' && event['@testrun'] === runName);
  assert.equal(states.length, 1, `${runName} must emit its actual applied state`);
  const outputs = states[0].test_state.outputs;
  const findings = validateDocument(outputs, { schema, requireQualified });
  assert.deepEqual(findings, [], `${runName}: ${JSON.stringify(findings)}`);
  for (const name of ['deployment_contract', 'validation_contract', 'operations_contract', 'operator_contract']) {
    assert.equal(outputs[name].sensitive, false, `${runName}: ${name} must remain non-secret`);
  }
}
console.log('PASS: 4 applied Lambda contracts satisfy schema, identity, digest and secret-reference joins; all 8 scenarios passed');
