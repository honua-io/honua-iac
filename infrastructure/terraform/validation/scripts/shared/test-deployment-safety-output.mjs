#!/usr/bin/env node
// Validate the actual mock-applied operator root output as well as HCL assertions.
// Only a successful complete test run with all three expected states counts.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { validateDocument } from './validate-operator-contract.mjs';
const schema = JSON.parse(readFileSync(new URL('../../../contracts/operator-contract.v1.schema.json', import.meta.url)));
const events = readFileSync(process.argv[2], 'utf8').trim().split('\n').map(line => JSON.parse(line));
const summary = events.find(event => event.type === 'test_summary')?.test_summary;
assert.equal(summary?.status, 'pass', 'Terraform root tests must pass');
assert.equal(summary.passed, 3, 'all operator root scenarios must run');
const states = events.filter(event => event.type === 'test_state');
assert.equal(states.length, 3, 'verbose output must contain each applied root state');
for (const state of states) {
  const findings = validateDocument(state.test_state.outputs, { schema });
  assert.deepEqual(findings, [], `${state['@testrun']}: ${JSON.stringify(findings)}`);
}
console.log('PASS: all 3 applied operator contracts validate, including native identity/digest/prerequisite joins');
