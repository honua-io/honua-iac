#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { validateDocument } from './validate-operator-contract.mjs';

const fixture = name => JSON.parse(readFileSync(new URL(`../../../contracts/fixtures/${name}`, import.meta.url)));
const schema = JSON.parse(readFileSync(new URL('../../../contracts/operator-contract.v2.schema.json', import.meta.url)));
const endpointFindings = document => validateDocument(document, { schema })
  .filter(finding => finding.code === 'E_ENDPOINT_MISMATCH');

const lambda = fixture('valid-aws-cert-lambda.json');
lambda.deployment_contract.value.endpoints.public_base_url = 'https://maps.example.com/honua';
for (const [name, url] of Object.entries(lambda.validation_contract.value.tests)) {
  if (typeof url === 'string') {
    lambda.validation_contract.value.tests[name] = url.replace(/^https:\/\/[^/]+/, 'https://maps.example.com/honua');
  }
}
assert.deepEqual(endpointFindings(lambda), [], 'Lambda API Gateway ingress may differ from its configured public origin');

lambda.deployment_contract.value.stack.runtime = 'container';
assert(endpointFindings(lambda).some(finding => finding.path === '$.deployment_contract.dependencies.ingress.endpoint'),
  'The public-origin exception requires an explicit Lambda stack');
lambda.deployment_contract.value.stack.runtime = 'lambda';

lambda.validation_contract.value.tests.readiness_url = 'https://other.example.com/healthz/ready';
assert(endpointFindings(lambda).some(finding => finding.path === '$.validation_contract.tests.readiness_url'),
  'Lambda validation URLs must still use the configured public origin');

const ecs = fixture('valid-aws-ecs-small.json');
ecs.deployment_contract.value.dependencies.ingress.endpoint = 'https://other.example.com';
assert(endpointFindings(ecs).some(finding => finding.path === '$.deployment_contract.dependencies.ingress.endpoint'),
  'Non-Lambda ingress must still agree with its declared public base URL');

console.log('PASS: Lambda public origin and ingress split is narrow; validation URLs and non-Lambda ingress remain guarded');
