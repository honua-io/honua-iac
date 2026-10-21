#!/usr/bin/env node
// Check the actual mock-applied customer root output against the consumer's
// schema/digest rules. A synthetic JSON fixture cannot prove this projection.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { SchemaValidator, validateDocument } from './validate-operator-contract.mjs';

const schema = JSON.parse(readFileSync(new URL('../../../contracts/operator-contract.v2.schema.json', import.meta.url)));
const runtimeSchema = JSON.parse(readFileSync(new URL('../../../contracts/runtime-binding.v1.schema.json', import.meta.url)));
const runtimeValidator = new SchemaValidator(runtimeSchema);
const events = readFileSync(process.argv[2], 'utf8').trim().split('\n').map(line => JSON.parse(line));
// Verbose Terraform JSON contains full planned/applied state. On failure expose
// only bounded diagnostic titles, locations and run status, never raw state.
if (process.argv[3] === '--diagnostics-only') {
  const safe = value => String(value ?? '').replace(/[\x00-\x1f\x7f]+/g, ' ').slice(0, 240);
  const runs = events.filter(event => event.type === 'test_run');
  runs.sort((a, b) => Number(['fail', 'error'].includes(b.test_run?.status)) - Number(['fail', 'error'].includes(a.test_run?.status)));
  for (const event of runs.slice(0, 16)) {
    console.error(`Terraform test ${safe(event['@testrun'])}: ${safe(event.test_run?.status)}`);
  }
  const diagnostics = events.filter(event => event.type === 'diagnostic');
  diagnostics.sort((a, b) => Number(b.diagnostic?.severity === 'error') - Number(a.diagnostic?.severity === 'error'));
  for (const event of diagnostics.slice(0, 12)) {
    const range = event.diagnostic?.range;
    const location = range?.filename && Number.isSafeInteger(range.start?.line)
      ? ` (${safe(range.filename)}:${range.start.line})` : '';
    console.error(`Terraform ${safe(event.diagnostic?.severity)}: ${safe(event.diagnostic?.summary)}${location}`);
  }
  const summary = events.findLast(event => event.type === 'test_summary')?.test_summary;
  if (summary) console.error(`Terraform summary: ${summary.passed} passed, ${summary.failed} failed, ${summary.errored} errored`);
  process.exit(0);
}
const summary = events.find(event => event.type === 'test_summary')?.test_summary;
assert.equal(summary?.status, 'pass', 'Terraform root tests must pass');
const completedPasses = new Set(events
  .filter(event => event.type === 'test_run' && event.test_run?.progress === 'complete' && event.test_run?.status === 'pass')
  .map(event => event.test_run.run));
const requiredRuns = [
  'unqualified_development_contract',
  'qualified_lambda_contract',
  'configured_public_origin_projects_without_retargeting_ingress',
  'older_alias_cannot_claim_current_dependency_settings',
  'serving_alias_image_mismatch_refused',
  'serving_alias_role_mismatch_refused',
  'marketplace_image_override_cannot_bypass_identity',
  'proxy_and_shared_storage_are_real_runtime_dependencies',
  'external_database_is_not_claimed_as_managed',
];
for (const runName of requiredRuns) {
  assert(completedPasses.has(runName), `${runName} must complete successfully`);
}
const positiveRuns = new Map([
  ['unqualified_development_contract', false],
  ['qualified_lambda_contract', true],
  ['configured_public_origin_projects_without_retargeting_ingress', false],
  ['proxy_and_shared_storage_are_real_runtime_dependencies', true],
  ['external_database_is_not_claimed_as_managed', true],
]);
for (const [runName, requireQualified] of positiveRuns) {
  const states = events.filter(event => event.type === 'test_state' && event['@testrun'] === runName);
  assert.equal(states.length, 1, `${runName} must emit its actual applied state`);
  const outputs = states[0].test_state.outputs;
  const findings = validateDocument(outputs, { schema, requireQualified });
  assert.deepEqual(findings, [], `${runName}: ${JSON.stringify(findings)}`);
  assert.equal(outputs.runtime_binding_contract?.sensitive, false, `${runName}: runtime identity must be credential-free`);
  assert.deepEqual(runtimeValidator.validate(outputs.runtime_binding_contract.value), [],
    `${runName}: actual Lambda runtime identity must satisfy the strict v1 schema`);
  for (const name of ['deployment_contract', 'validation_contract', 'operations_contract', 'operator_contract']) {
    assert.equal(outputs[name].sensitive, false, `${runName}: ${name} must remain non-secret`);
  }
}
console.log('PASS: 5 applied Lambda contracts satisfy schema, identity, digest and secret-reference joins; all required Lambda scenarios passed');
