#!/usr/bin/env node
// Regenerates the honua.operator-contract/v1 fixture corpus.
//
//   node infrastructure/terraform/contracts/fixtures/make-fixtures.mjs
//
// The fixtures are checked in so the corpus is reviewable and so honua-devops
// and honua-release can consume the same bytes. They are generated rather than
// hand-written because every one of them carries a contract digest, and a
// hand-edited digest is a fixture that tests nothing.
//
// Most negative fixtures deliberately keep a correct digest: a document that
// hashes correctly but still violates a semantic rule is the case a naive
// consumer would wave through.

import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createHash } from 'node:crypto';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCHEMA_VERSION = 'honua.operator-contract/v1';
const CONTRACT_KEYS = ['deployment_contract', 'validation_contract', 'operations_contract'];

const ACCOUNT = '123456789012';
const OTHER_ACCOUNT = '210987654321';
const REGION = 'us-east-1';
const PARTITION = 'aws';
const BASE_NAME = 'honuaecs-it';
const CLUSTER = `${BASE_NAME}-cluster`;
const SERVICE = `${BASE_NAME}-service`;
const BASE_URL = 'https://honua.example.com';
const IMAGE_DIGEST = 'sha256:2f5c1d0e9b7a43c68d1f0a5e4b3c2d1908f7e6d5c4b3a29180716253d4c5b6a7';
const IMAGE_REFERENCE = `ghcr.io/honua-io/honua@${IMAGE_DIGEST}`;
const SECRETS_PREFIX = `arn:${PARTITION}:secretsmanager:${REGION}:${ACCOUNT}:secret:`;

const secretArn = (name) => `${SECRETS_PREFIX}${BASE_NAME}-${name}-AbCdEf`;

// --------------------------------------------------------------------------

const CONTROL_CHARS = /[\u0000-\u001f\u007f]/;
const LINE_SEPARATORS = /[\u2028\u2029]/;
const ASCII_PRINTABLE = /^[\x20-\x7e]+$/;

function canonicalString(value) {
  if (CONTROL_CHARS.test(value)) throw new Error('control character in string');
  if (LINE_SEPARATORS.test(value)) throw new Error('U+2028/U+2029 in string');
  return JSON.stringify(value)
    .replaceAll('<', '\\u003c')
    .replaceAll('>', '\\u003e')
    .replaceAll('&', '\\u0026');
}

function canonicalize(value) {
  if (value === null) return 'null';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') {
    if (!Number.isSafeInteger(value)) throw new Error(`non-integer number: ${value}`);
    return String(value);
  }
  if (typeof value === 'string') return canonicalString(value);
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(',')}]`;
  const keys = Object.keys(value).sort();
  for (const key of keys) {
    if (!ASCII_PRINTABLE.test(key)) throw new Error(`non-ASCII object key: ${key}`);
  }
  return `{${keys.map((k) => `${canonicalString(k)}:${canonicalize(value[k])}`).join(',')}}`;
}

const sha256Hex = (text) => createHash('sha256').update(text, 'utf8').digest('hex');

// --------------------------------------------------------------------------

function qualifiedIdentity() {
  return {
    status: 'qualified',
    contract_digest: null,
    candidate_digest: 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90',
    manifest_digest: '0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0',
    iac_revision: '9c1e7f0b2d3a4c5e6f708192a3b4c5d6e7f80912',
    iac_root: 'infrastructure/terraform/examples/aws',
    module_source: 'infrastructure/terraform/modules/aws-ecs',
    terraform_version: '1.9.8',
    provider_lock_digest: '5d4c3b2a1908f7e6d5c4b3a29180716253d4c5b6a7f8e9d0c1b2a3948576a6b5',
    image_reference: IMAGE_REFERENCE,
    image_digest: IMAGE_DIGEST,
    backend_config_digest: 'c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4',
    state_lineage: '8f3b1c2d-4e5a-4b6c-9d7e-0a1b2c3d4e5f',
    state_serial: 42,
    workload_identity: `arn:${PARTITION}:iam::${ACCOUNT}:role/${BASE_NAME}-task`,
    artifacts: [
      {
        name: 'honua-proxy',
        kind: 'proxy',
        version: '2026.1.0',
        digest: 'b7a6958473625140f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788',
      },
    ],
    platform: {
      provider: 'aws',
      partition: PARTITION,
      account_id: ACCOUNT,
      region: REGION,
    },
  };
}

function unqualifiedIdentity() {
  return {
    status: 'unqualified',
    contract_digest: null,
    candidate_digest: null,
    manifest_digest: null,
    iac_revision: null,
    iac_root: 'infrastructure/terraform/examples/aws',
    module_source: 'infrastructure/terraform/modules/aws-ecs',
    terraform_version: null,
    provider_lock_digest: null,
    image_reference: null,
    image_digest: null,
    backend_config_digest: null,
    state_lineage: null,
    state_serial: null,
    workload_identity: null,
    artifacts: [],
    platform: {
      provider: 'aws',
      partition: PARTITION,
      account_id: ACCOUNT,
      region: REGION,
    },
  };
}

function contracts(identity) {
  const deployment = {
    schema_version: SCHEMA_VERSION,
    kind: 'deployment',
    identity,
    stack: {
      id: 'aws-ecs',
      platform: 'aws',
      runtime: 'ecs-fargate',
      environment: 'it',
      region: REGION,
      account_id: ACCOUNT,
      name_prefix: 'honuaecs',
    },
    endpoints: {
      public_base_url: BASE_URL,
      readiness_path: '/healthz/ready',
      admin_base_path: '/api/v1/admin',
      protocol_path: '/v1',
      mcp_path: '/mcp',
      ingress_dns_name: 'honuaecs-it-alb-1234567890.us-east-1.elb.amazonaws.com',
      custom_domain: 'honua.example.com',
    },
    workload: {
      kind: 'AwsEcs',
      name: SERVICE,
      resource_id: `arn:${PARTITION}:ecs:${REGION}:${ACCOUNT}:service/${CLUSTER}/${SERVICE}`,
      cluster_name: CLUSTER,
      cluster_id: `arn:${PARTITION}:ecs:${REGION}:${ACCOUNT}:cluster/${CLUSTER}`,
      cpu_architecture: 'X86_64',
      desired_count: 1,
      identity: identity.workload_identity,
    },
    rollout: {
      backend_name: 'honua-gitops-aws-ecs',
      target_kind: 'AwsEcs',
      target_id: SERVICE,
      target_name: SERVICE,
      target_resource: `arn:${PARTITION}:ecs:${REGION}:${ACCOUNT}:cluster/${CLUSTER}`,
      current_revision: null,
      desired_revision: null,
      canary: {
        enabled: false,
        service_name: null,
        target_group_arn: null,
        weight_percentage: 0,
        verification_header_name: null,
      },
    },
    dependencies: {
      database: {
        kind: 'aws-rds-postgres',
        managed: true,
        endpoint: `${BASE_NAME}-db.abcdefghij.${REGION}.rds.amazonaws.com`,
        secret_ref: secretArn('db-connection'),
      },
      cache: {
        kind: 'aws-elasticache-redis',
        enabled: true,
        secret_ref: secretArn('redis-connection'),
      },
      ingress: {
        kind: 'aws-alb',
        endpoint: BASE_URL,
        certificate_ref: `arn:${PARTITION}:acm:${REGION}:${ACCOUNT}:certificate/11111111-2222-3333-4444-555555555555`,
        waf_ref: null,
      },
      object_storage: {
        kind: null,
        enabled: false,
        bucket: null,
        prefix: null,
      },
    },
    secret_refs: {
      admin_password: secretArn('admin-password'),
      connection_encryption_master_key: secretArn('master-key'),
      db_connection: secretArn('db-connection'),
      redis_connection: secretArn('redis-connection'),
    },
  };

  const validation = {
    schema_version: SCHEMA_VERSION,
    kind: 'validation',
    identity,
    platform: {
      name: 'aws-ecs',
      capabilities: {
        deploy_plan: true,
        mutation: true,
        scale_check: false,
        backup_drill: true,
        idempotency: true,
        http_protocol: true,
        mcp: true,
      },
    },
    tests: {
      readiness_url: `${BASE_URL}/healthz/ready`,
      admin_url: `${BASE_URL}/api/v1/admin`,
      protocol_url: `${BASE_URL}/v1`,
      mcp_url: `${BASE_URL}/mcp`,
    },
    mcp: {
      enabled: true,
      profile: 'honua.mcp/operator.v1',
      transport: 'http',
      required_tools: ['honua.search', 'honua.ingest', 'honua.admin.status'],
    },
    test_data: {
      seed_mode: 'smoke',
      tenant_prefix: 'honua-it',
      reuse_data_stack: false,
      admin_credential_ref: secretArn('admin-password'),
    },
    artifacts: {
      terraform_root: 'infrastructure/terraform/examples/aws',
      module_source: 'infrastructure/terraform/modules/aws-ecs',
      image_reference: identity.image_reference,
      image_digest: identity.image_digest,
      pins: identity.artifacts,
    },
    lifecycle: {
      reuse_data_stack: false,
      destroy_mode: 'ephemeral',
      ttl_hours: 8,
    },
    selectors: {
      account_id: ACCOUNT,
      region: REGION,
      cluster_arn: `arn:${PARTITION}:ecs:${REGION}:${ACCOUNT}:cluster/${CLUSTER}`,
      service_arn: `arn:${PARTITION}:ecs:${REGION}:${ACCOUNT}:service/${CLUSTER}/${SERVICE}`,
      log_group: `/honua/${BASE_NAME}`,
      tag_filters: { Project: 'honua', Environment: 'it' },
    },
  };

  const operations = {
    schema_version: SCHEMA_VERSION,
    kind: 'operations',
    identity,
    observability: {
      telemetry_policy: 'honua-http',
      prometheus_job: 'honua',
      prometheus_canary_job: null,
      log_group: `/honua/${BASE_NAME}`,
      metrics_namespace: `Honua/${BASE_NAME}`,
    },
    secrets: {
      provider: 'aws-secretsmanager',
      references: {
        admin_password: {
          kind: 'admin_password',
          provider: 'aws-secretsmanager',
          id: secretArn('admin-password'),
          kms_key_ref: null,
          managed_by: 'honua-iac',
        },
        connection_encryption_master_key: {
          kind: 'connection_encryption_master_key',
          provider: 'aws-secretsmanager',
          id: secretArn('master-key'),
          kms_key_ref: null,
          managed_by: 'honua-iac',
        },
        db_connection: {
          kind: 'db_connection',
          provider: 'aws-secretsmanager',
          id: secretArn('db-connection'),
          kms_key_ref: null,
          managed_by: 'honua-iac',
        },
        redis_connection: {
          kind: 'redis_connection',
          provider: 'aws-secretsmanager',
          id: secretArn('redis-connection'),
          kms_key_ref: null,
          managed_by: 'honua-iac',
        },
      },
    },
    scaling: {
      deployment_mode: 'SingleInstance',
      desired_count: 1,
      max_capacity: 2,
      cpu_architecture: 'X86_64',
    },
    resilience: {
      ingress_deletion_protection: false,
      ingress_access_logs_enabled: true,
      database_managed: true,
      cache_enabled: true,
    },
    grouping: {
      resource_group: CLUSTER,
      name_prefix: 'honuaecs',
      tags: { Project: 'honua', Environment: 'it' },
    },
    cost: {
      owner: 'honua-release',
      ephemeral: true,
      ttl_hours: 8,
    },
    state: {
      terraform_root: 'infrastructure/terraform/examples/aws',
      backend_config_digest: identity.backend_config_digest,
      lineage: identity.state_lineage,
      serial: identity.state_serial,
    },
  };

  return { deployment, validation, operations };
}

function sealDigest(envelope) {
  const stripped = {};
  for (const key of CONTRACT_KEYS) {
    const clone = structuredClone(envelope[key]);
    delete clone.identity.contract_digest;
    stripped[key] = clone;
  }
  const digest = sha256Hex(
    canonicalize({ schema_version: SCHEMA_VERSION, ...stripped }),
  );
  for (const key of CONTRACT_KEYS) envelope[key].identity.contract_digest = digest;
  return digest;
}

function buildEnvelope(identity) {
  const { deployment, validation, operations } = contracts(identity);
  const envelope = {
    deployment_contract: deployment,
    validation_contract: validation,
    operations_contract: operations,
  };
  sealDigest(envelope);
  return envelope;
}

// Wrap contracts the way `terraform output -json` does, including the legacy
// scalar outputs, so the validator is exercised against a real document shape.
function terraformOutputDocument(envelope) {
  const wrap = (value, sensitive = false) => ({ sensitive, type: 'dynamic', value });
  return {
    honua_url: wrap(envelope.deployment_contract.endpoints.public_base_url),
    ecs_cluster_name: wrap(envelope.deployment_contract.workload.cluster_name),
    ecs_service_name: wrap(envelope.deployment_contract.workload.name),
    operator_contract_status: wrap(envelope.deployment_contract.identity.status),
    operator_contract_digest: wrap(envelope.deployment_contract.identity.contract_digest),
    deployment_contract: wrap(envelope.deployment_contract),
    validation_contract: wrap(envelope.validation_contract),
    operations_contract: wrap(envelope.operations_contract),
  };
}

function write(name, document) {
  const path = join(HERE, name);
  writeFileSync(path, `${JSON.stringify(document, null, 2)}\n`);
  process.stdout.write(`wrote ${name}\n`);
}

// -- positive ---------------------------------------------------------------

const qualified = buildEnvelope(qualifiedIdentity());
write('valid-aws-ecs-small.json', terraformOutputDocument(qualified));

const unqualified = buildEnvelope(unqualifiedIdentity());
write('valid-aws-ecs-small-unqualified.json', terraformOutputDocument(unqualified));

// -- negative ---------------------------------------------------------------

function mutate(fn, { reseal = true } = {}) {
  const envelope = buildEnvelope(qualifiedIdentity());
  fn(envelope);
  if (reseal) sealDigest(envelope);
  return terraformOutputDocument(envelope);
}

write(
  'invalid-missing-required-field.json',
  mutate((envelope) => {
    delete envelope.deployment_contract.workload.cluster_name;
  }),
);

write(
  'invalid-unknown-schema-version.json',
  mutate((envelope) => {
    for (const key of CONTRACT_KEYS) {
      envelope[key].schema_version = 'honua.operator-contract/v2';
    }
  }),
);

write(
  'invalid-mutable-image-tag.json',
  mutate((envelope) => {
    const reference = 'ghcr.io/honua-io/honua:2026.1.0';
    for (const key of CONTRACT_KEYS) envelope[key].identity.image_reference = reference;
    envelope.validation_contract.artifacts.image_reference = reference;
  }),
);

write(
  'invalid-secret-value-leak.json',
  mutate((envelope) => {
    envelope.deployment_contract.dependencies.database.endpoint =
      'postgres://honua_admin:hunter2-not-a-reference@honuaecs-it-db.abcdefghij.us-east-1.rds.amazonaws.com:5432/honua';
  }),
);

// The one fixture that must NOT be resealed: correct-looking contract bytes
// carrying a substituted digest.
write(
  'invalid-contract-digest-mismatch.json',
  mutate(
    (envelope) => {
      const substituted = 'deadbeef'.repeat(8);
      for (const key of CONTRACT_KEYS) envelope[key].identity.contract_digest = substituted;
    },
    { reseal: false },
  ),
);

write(
  'invalid-account-mismatch.json',
  mutate((envelope) => {
    envelope.validation_contract.selectors.account_id = OTHER_ACCOUNT;
  }),
);

write(
  'invalid-endpoint-mismatch.json',
  mutate((envelope) => {
    envelope.validation_contract.tests.readiness_url =
      'https://attacker.example.net/healthz/ready';
  }),
);

write(
  'invalid-identity-mismatch.json',
  mutate((envelope) => {
    envelope.operations_contract.identity = {
      ...envelope.operations_contract.identity,
      state_serial: 41,
    };
  }),
);

write(
  'invalid-secret-ref-mismatch.json',
  mutate((envelope) => {
    envelope.operations_contract.secrets.references.admin_password.id = secretArn('other-secret');
  }),
);

// The digest input, so a Terraform-side check can prove that jsonencode()
// reproduces the canonical bytes this corpus was hashed with.
{
  const envelope = buildEnvelope(qualifiedIdentity());
  const stripped = {};
  for (const key of CONTRACT_KEYS) {
    const clone = structuredClone(envelope[key]);
    delete clone.identity.contract_digest;
    stripped[key] = clone;
  }
  write('canonical-digest-input.json', { schema_version: SCHEMA_VERSION, ...stripped });
  write('canonical-digest-expected.json', {
    schema_version: SCHEMA_VERSION,
    contract_digest: envelope.deployment_contract.identity.contract_digest,
  });
}
