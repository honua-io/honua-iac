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

// -- examples/aws-cert (modules/aws-serverless: Lambda + HTTP API Gateway) ---
// The certification root's shapes differ from the ECS root's in ways the
// corpus has to carry, or the validator is only ever exercised against one
// runtime: a Lambda alias instead of an ECS service, no cluster, no canary,
// an extensions block, and a contract whose iac_root is examples/aws-cert.
const CERT_NAME = 'honua-cert-cert';
const CERT_FUNCTION = `${CERT_NAME}-honua`;
const CERT_BASE_URL = 'https://a1b2c3d4e5.execute-api.us-east-1.amazonaws.com';
const CERT_ROOT = 'infrastructure/terraform/examples/aws-cert';
const CERT_MODULE = 'infrastructure/terraform/modules/aws-serverless';
const CERT_BUCKET = `${CERT_NAME}-artifacts-9f8e7d6c`;
const CERT_TAGS = {
  Project: 'honua-server',
  Environment: 'cert',
  ManagedBy: 'terraform',
  Purpose: 'real-aws-certification',
};

const certSecretArn = (name) => `${SECRETS_PREFIX}${CERT_NAME}-${name}-AbCdEf`;

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

function certQualifiedIdentity() {
  return {
    ...qualifiedIdentity(),
    iac_root: CERT_ROOT,
    module_source: CERT_MODULE,
    workload_identity: `arn:${PARTITION}:iam::${ACCOUNT}:role/${CERT_FUNCTION}-role`,
  };
}

// Additive certification facts, byte-identical across the three contracts the
// way examples/aws-cert/operator-contract.tf emits them.
function certExtensions() {
  const batchArn = (kind, name) => `arn:${PARTITION}:batch:${REGION}:${ACCOUNT}:${kind}/${name}`;
  return {
    artifact_bucket: CERT_BUCKET,
    customcode_batch: {
      enabled: false,
      job_definition_arns: {},
      job_queue_arn: null,
      runtimes: [],
      task_role_arn: null,
    },
    ecs_alb_cutover_cell: {
      canary_target_group_arn: null,
      cluster_arn: null,
      cluster_name: null,
      enabled: false,
      listener_arn: null,
      service_name: null,
      stable_target_group_arn: null,
    },
    geoprocessing_batch: {
      compute_environment: batchArn('compute-environment', `${CERT_NAME}-gp`),
      control_plane_backend: 'honua-gitops-aws-batch',
      enabled: true,
      execution_role_arn: `arn:${PARTITION}:iam::${ACCOUNT}:role/${CERT_NAME}-gp-execution`,
      job_definition_arns: {
        l: batchArn('job-definition', `${CERT_NAME}-gp-l:1`),
        m: batchArn('job-definition', `${CERT_NAME}-gp-m:1`),
        s: batchArn('job-definition', `${CERT_NAME}-gp-s:1`),
        xl: batchArn('job-definition', `${CERT_NAME}-gp-xl:1`),
      },
      job_queue_arn: batchArn('job-queue', `${CERT_NAME}-gp`),
      job_role_arn: `arn:${PARTITION}:iam::${ACCOUNT}:role/${CERT_NAME}-gp-job`,
      workload_id: 'geoprocessing-batch',
    },
    github_oidc_role_arn: `arn:${PARTITION}:iam::${ACCOUNT}:role/${CERT_NAME}-github-oidc`,
  };
}

function certContracts(identity) {
  const extensions = certExtensions();
  const logGroup = `/aws/lambda/${CERT_FUNCTION}`;

  const deployment = {
    schema_version: SCHEMA_VERSION,
    kind: 'deployment',
    identity,
    extensions,
    stack: {
      id: 'aws-cert-serverless',
      platform: 'aws',
      runtime: 'lambda',
      environment: 'cert',
      region: REGION,
      account_id: ACCOUNT,
      name_prefix: 'honua-cert',
    },
    endpoints: {
      public_base_url: CERT_BASE_URL,
      readiness_path: '/healthz/ready',
      admin_base_path: '/api/v1/admin',
      protocol_path: '/v1',
      mcp_path: null,
      ingress_dns_name: 'a1b2c3d4e5.execute-api.us-east-1.amazonaws.com',
      custom_domain: null,
    },
    workload: {
      kind: 'AwsLambda',
      name: CERT_FUNCTION,
      resource_id: `arn:${PARTITION}:lambda:${REGION}:${ACCOUNT}:function:${CERT_FUNCTION}:live`,
      // No cluster exists for a Lambda alias; the stack's resource-group name
      // stands in for v1's required cluster_name and cluster_id stays null.
      cluster_name: CERT_NAME,
      cluster_id: null,
      cpu_architecture: 'x86_64',
      desired_count: 0,
      identity: identity.workload_identity,
    },
    rollout: {
      backend_name: 'honua-gitops-aws-lambda',
      target_kind: 'AwsLambda',
      target_id: `${CERT_FUNCTION}-live`,
      target_name: CERT_FUNCTION,
      target_resource: `arn:${PARTITION}:lambda:${REGION}:${ACCOUNT}:function:${CERT_FUNCTION}:live`,
      // A Lambda alias's function version is Terraform-owned state, so unlike
      // the ECS root these are projected rather than nulled.
      current_revision: '7',
      desired_revision: '7',
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
        endpoint: `${CERT_NAME}-db.abcdefghij.${REGION}.rds.amazonaws.com`,
        secret_ref: certSecretArn('db-connection'),
      },
      cache: {
        kind: 'aws-elasticache-redis',
        enabled: false,
        secret_ref: null,
      },
      ingress: {
        kind: 'aws-apigatewayv2-http',
        endpoint: CERT_BASE_URL,
        certificate_ref: null,
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
      admin_password: certSecretArn('admin-password'),
      db_connection: certSecretArn('db-connection'),
    },
  };

  const validation = {
    schema_version: SCHEMA_VERSION,
    kind: 'validation',
    identity,
    extensions,
    platform: {
      name: 'aws-cert-serverless',
      capabilities: {
        deploy_plan: true,
        mutation: false,
        scale_check: false,
        backup_drill: true,
        idempotency: true,
        http_protocol: true,
        mcp: false,
      },
    },
    tests: {
      readiness_url: `${CERT_BASE_URL}/healthz/ready`,
      admin_url: `${CERT_BASE_URL}/api/v1/admin`,
      protocol_url: `${CERT_BASE_URL}/v1`,
      mcp_url: null,
    },
    mcp: {
      enabled: false,
      profile: null,
      transport: null,
      required_tools: [],
    },
    test_data: {
      seed_mode: 'smoke',
      tenant_prefix: 'honua-cert',
      reuse_data_stack: false,
      admin_credential_ref: certSecretArn('admin-password'),
    },
    artifacts: {
      terraform_root: CERT_ROOT,
      module_source: CERT_MODULE,
      image_reference: identity.image_reference,
      image_digest: identity.image_digest,
      pins: identity.artifacts,
    },
    lifecycle: {
      reuse_data_stack: false,
      destroy_mode: 'ephemeral',
      ttl_hours: null,
    },
    selectors: {
      account_id: ACCOUNT,
      region: REGION,
      // A Lambda workload has neither a cluster nor a service.
      cluster_arn: null,
      service_arn: null,
      log_group: logGroup,
      tag_filters: CERT_TAGS,
    },
  };

  const operations = {
    schema_version: SCHEMA_VERSION,
    kind: 'operations',
    identity,
    extensions,
    observability: {
      telemetry_policy: 'honua-http',
      prometheus_job: null,
      prometheus_canary_job: null,
      log_group: logGroup,
      metrics_namespace: `Honua/${CERT_NAME}`,
    },
    secrets: {
      provider: 'aws-secretsmanager',
      references: {
        admin_password: {
          kind: 'admin_password',
          provider: 'aws-secretsmanager',
          id: certSecretArn('admin-password'),
          kms_key_ref: null,
          managed_by: 'honua-iac',
        },
        db_connection: {
          kind: 'db_connection',
          provider: 'aws-secretsmanager',
          id: certSecretArn('db-connection'),
          kms_key_ref: null,
          managed_by: 'honua-iac',
        },
      },
    },
    scaling: {
      deployment_mode: 'Serverless',
      desired_count: 0,
      max_capacity: 0,
      cpu_architecture: 'x86_64',
    },
    resilience: {
      ingress_deletion_protection: false,
      ingress_access_logs_enabled: true,
      database_managed: true,
      cache_enabled: false,
    },
    grouping: {
      resource_group: CERT_NAME,
      name_prefix: 'honua-cert',
      tags: CERT_TAGS,
    },
    cost: {
      owner: null,
      ephemeral: true,
      ttl_hours: null,
    },
    state: {
      terraform_root: CERT_ROOT,
      backend_config_digest: identity.backend_config_digest,
      lineage: identity.state_lineage,
      serial: identity.state_serial,
    },
  };

  return { deployment, validation, operations };
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

function buildEnvelope(identity, shape = contracts) {
  const { deployment, validation, operations } = shape(identity);
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

// The certification root's own `terraform output -json` shape. Its scalar
// outputs are the GP/custom-code substrate runtime contract the honua-server
// cert fixture consumes -- they are NOT legacy scalars superseded by the
// operator contract, so they carry no deprecation marker.
function certTerraformOutputDocument(envelope) {
  const wrap = (value, sensitive = false) => ({ sensitive, type: 'dynamic', value });
  const extensions = envelope.deployment_contract.extensions;
  return {
    honua_api_endpoint: wrap(envelope.deployment_contract.endpoints.public_base_url),
    cert_artifact_bucket: wrap(extensions.artifact_bucket),
    gp_job_queue_arn: wrap(extensions.geoprocessing_batch.job_queue_arn),
    gp_job_definition_arns: wrap(extensions.geoprocessing_batch.job_definition_arns),
    github_oidc_role_arn: wrap(extensions.github_oidc_role_arn),
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

// examples/aws-cert. A second runtime in the positive corpus, so the rules the
// validator enforces are proven against a Lambda/API-Gateway projection with an
// extensions block and no cluster -- not only against the ECS root.
const certQualified = buildEnvelope(certQualifiedIdentity(), certContracts);
write('valid-aws-cert-lambda.json', certTerraformOutputDocument(certQualified));

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
