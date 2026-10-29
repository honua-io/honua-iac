# AWS EKS Module

Provisions an Amazon EKS cluster and everything the Honua Helm chart needs
from AWS to run a full deployment on it: the VPC, the managed node group, an
RDS PostgreSQL (+ PostGIS) datastore, optional ElastiCache Redis, the runtime
secrets, workload IAM roles for the server and GP Kubernetes Job pods, and an
optional ACM certificate and Route53 record for a custom hostname.

> Internal-only; not part of the published module surface. See
> [`docs/module-versioning.md`](../../../../docs/module-versioning.md).

The module creates **no Kubernetes objects**. The honua-helm chart installs the
server, its service accounts, the GP Job RBAC and the LoadBalancer Service; the
module's outputs are the values the chart and the release harness need.

For the governed native install against an existing cluster, use
[`examples/aws-eks-native`](../../examples/aws-eks-native/README.md). That
separate Terraform root owns the Kubernetes Deployment, Service, service
accounts, Job RBAC and configured public route without a chart write step.

## What it provisions

- VPC with public/private subnets and a NAT gateway
- EKS control plane and a managed node group (role `<name_prefix>-<environment>-eks-node`)
- Add-ons: coredns, kube-proxy, vpc-cni, and eks-pod-identity-agent (Pod Identity mode)
- RDS PostgreSQL (`rds.force_ssl`), optional PostGIS bootstrap; or an existing database
- Optional ElastiCache Redis (TLS in transit, encrypted at rest, AUTH token)
- Secrets Manager secrets: database connection string, admin password,
  connection-encryption master key, Redis connection string
- IAM roles `<name>-server` and `<name>-gp-job`, bound to their service accounts
- Optional ACM certificate (DNS-validated) and Route53 record for `domain_name`

## Workload identity

| `workload_identity_mode` | How pods get credentials | Chart work |
| --- | --- | --- |
| `pod_identity` (default) | EKS Pod Identity associations made through the EKS API; the eks-pod-identity-agent add-on is installed. No IAM OIDC provider. | Run the server as `server_service_account_name` in `kubernetes_namespace` and GP Jobs as `gp_job_service_account_name` in `gp_job_namespace`. No annotations. |
| `irsa` | The EKS module creates the cluster's IAM OIDC provider; each role trusts exactly one `system:serviceaccount:<ns>:<sa>`. | Also apply `server_service_account_annotations` / `gp_job_service_account_annotations` (`eks.amazonaws.com/role-arn`). |

Under `pod_identity`, do **not** put the `eks.amazonaws.com/role-arn` annotation
on the service accounts: the EKS IRSA webhook would inject a web-identity token
for a role that does not trust any OIDC provider, and the AWS SDK tries web
identity before the Pod Identity container credentials. Annotate only with the
`*_service_account_annotations` outputs, which are empty in this mode.

Pod Identity is the default because an IAM OIDC provider is an account-level
object: the release account's cell guardrail denies `iam:*OpenIDConnectProvider*`
outright, which is half of why e2e-cloud-aws run 38057015781 never provisioned
an EKS cell. The other half was the node-group role: the upstream default name
`default-eks-node-group-*` falls outside the cell's IAM name prefix, so the role
is now named under `<name_prefix>-<environment>`. Both workload roles are too.

Both workload roles read the database, admin password, master key, optional
Redis, key-ring and audit-chain secrets. The GP Job role needs the same set: the
chart's `geoprocessing.kubernetesJobs.envFromServer` mode (default on) imports the
server's runtime Secret and config ConfigMap into each worker, and honua-server
resolves every `aws:secretsmanager:` security reference at startup, so a reference
the worker cannot read fails the Job before it runs (honua-release#1059).
Customer-managed KMS decrypt grants are scoped to
the role's matching secret ARNs through the Secrets Manager encryption context. With
`gp_job_data_bucket_enabled`, both read and write `gp_job_data_bucket_arn`.

## GP on Kubernetes handoff

GP Kubernetes Job runners are configured on the server through
`ControlPlane:Kubernetes:*`. The module renders them into
`control_plane_kubernetes_environment` (and `honua_server_environment`):

| Setting | Source |
| --- | --- |
| `ControlPlane__Kubernetes__DefaultNamespace` | `gp_job_namespace`, else `kubernetes_namespace` |
| `ControlPlane__Kubernetes__DefaultServiceAccount` | `gp_job_service_account_name` |
| `ControlPlane__Kubernetes__DefaultImage` | `gp_job_image` (omitted when empty) |

The job service account itself and the RBAC that lets the server create Jobs
belong to the chart (honua-helm#77); the IAM role behind it is `gp_job_role_arn`.

## Server environment

Two maps, both name => value and both free of secret values:

- `chart_config_env` — what the chart's `config.env` needs **besides** the
  credentials: `ControlPlane__Kubernetes__*`, `Operations__Policy__Rules__*`,
  `Cors__AllowedOrigins__*`, `Public__BaseUrl` (see [Custom domain](#custom-domain)),
  and `aws:secretsmanager:` references to the operator-owned key-ring and
  audit-chain secrets. The release harness renders
  it into the chart values and writes the database, admin password, master key
  and Redis credentials into the chart's own Secret (from the sensitive
  `db_connection_string` / `redis_connection_string` outputs).
- `honua_server_environment` — the complete environment: `chart_config_env`
  plus the generated credentials as `aws:secretsmanager:` references, for an
  install that resolves every secret through the server's workload role.

`honua_server_environment` is the server's environment as a name/value map for
the chart's `env` values. Secrets never appear in it: each is an
`aws:secretsmanager:<arn>` reference the server resolves at startup with its
workload role, the same contract the aws-serverless Lambda and GP Batch
containers use.

| Entry | When |
| --- | --- |
| `ConnectionStrings__DefaultConnection` | always |
| `HONUA_ADMIN_PASSWORD` | always |
| `Security__ConnectionEncryption__MasterKey` | always |
| `ConnectionStrings__redis` | `redis_enabled` |
| `Operations__SecretChannel__KeyRingCertificatePkcs12` | `redis_enabled` with `operation_key_ring_certificate_secret_arn` |
| `AuditLog__ChainVerification__Key` | `audit_chain_key_secret_arn` set |
| `Operations__Policy__Rules__<n>__<Field>` | `operations_policy_rules` |
| `Cors__AllowedOrigins__<n>` | `cors_allowed_origins` |
| `ControlPlane__Kubernetes__*` | always (image only when set) |

## Inputs (GA cell)

The cluster inputs (`name_prefix`, `environment`, VPC CIDRs, node sizing,
endpoint access, `cluster_secret_encryption_*`) are unchanged. New inputs keep
the names and semantics of `modules/aws-ecs` and `modules/aws-serverless`:

| Input | Default | Notes |
| --- | --- | --- |
| `workload_identity_mode` | `pod_identity` | `pod_identity` or `irsa`. |
| `kubernetes_namespace` | `honua` | Namespace of the Helm release. |
| `server_service_account_name` | `honua` | Chart `serviceAccount.name`. |
| `gp_job_namespace` | `""` | Empty uses `kubernetes_namespace`. |
| `gp_job_service_account_name` | `honua-gp-job` | GP Job service account. |
| `gp_job_image` | `""` | GP Job image, pinned by digest. |
| `gp_job_data_bucket_arn` / `gp_job_data_bucket_enabled` | `""` / `false` | S3 bucket both workload roles may use; set together (the flag is plan-time known). |
| `permissions_boundary_arn` | `""` | Boundary for the workload roles. |
| `infrastructure_permissions_boundary_arn` | `""` | Boundary for the EKS cluster and managed node-group roles (required when deploying as the `bootstrap/aws-eks` user). |
| `existing_db_endpoint` / `existing_db_connection_string` | `""` | Both set: no RDS. |
| `db_username`, `db_name`, `db_password` | `honua`, `honua`, generated | Managed RDS credentials. |
| `db_instance_class`, `db_allocated_storage`, `db_max_allocated_storage`, `db_engine_version`, `db_multi_az` | `db.t3.micro`, 20, 100, `15`, `false` | RDS sizing. |
| `db_require_ssl` | `true` | `SSL Mode=Require` in the connection string. |
| `db_publicly_accessible` / `db_additional_ingress_cidrs` | `false` / `[]` | Validation cells only: lets the runner reach RDS for the PostGIS bootstrap. |
| `rds_deletion_protection` | `true` | Ephemeral cells set `false`. |
| `enable_postgis` | `false` | local-exec `psql` bootstrap; needs `db_publicly_accessible`. |
| `postgis_readiness_max_attempts` / `postgis_readiness_sleep_seconds` | 90 / 10 | Bootstrap readiness loop. |
| `admin_password` | generated | Bootstrap admin password (root: `honua_admin_password`). |
| `connection_encryption_master_key` | generated | New deployments only; existing ones pass their key (root: `honua_connection_encryption_master_key`). |
| `secrets_kms_key_arn` | `""` | CMK for the module's secrets; empty uses `aws/secretsmanager` so a throwaway cluster strands no CMK. |
| `redis_enabled` | `false` | ElastiCache Redis; requires the key-ring certificate. The `examples/aws-eks` root spells it `enable_redis` (the name the release harness passes to this root). |
| `redis_auth_token`, `redis_node_type`, `redis_engine_version`, `redis_parameter_group_name`, `redis_num_cache_clusters`, `redis_port` | generated, `cache.t3.micro`, `7.0`, `default.redis7`, 1, 6379 | Redis shape. |
| `operation_key_ring_certificate_secret_arn` / `_kms_key_arn` | `""` | Operator-owned PKCS#12 bundle; required with Redis. Only the ARN enters Terraform. |
| `audit_chain_key_secret_arn` / `_kms_key_arn` | `""` | Operator-owned audit hash-chain key; recommended (a check warns when empty). |
| `operations_policy_rules` | `[]` | Ordered first-match-wins rules, same shape as aws-ecs; rendered as `Operations__Policy__Rules__<n>__<Field>`. Production denies every typed operation until a rule allows it. |
| `cors_allowed_origins` | `[]` | Browser origins, same definition as aws-ecs; rendered as `Cors__AllowedOrigins__<n>`. |
| `domain_name` / `route53_zone_id` | `""` | Set together: DNS-validated ACM certificate for a hostname on any domain you own, and `Public__BaseUrl = https://<domain_name>` in `chart_config_env`. |
| `public_base_url` | `""` | Public origin for server-built absolute links, rendered as `Public__BaseUrl`; overrides the domain. Absolute `http`/`https` URL. |
| `subject_alternative_names` | `[]` | Extra certificate names. |
| `ingress_load_balancer_hostname` | `""` | The chart's load balancer DNS name, on a second apply: creates the Route53 CNAME for `domain_name`. |

## Custom domain

The chart creates the load balancer, after this module applies. So the domain
is two applies:

1. Apply with `domain_name` and `route53_zone_id`. The module issues and
   validates the certificate and outputs `ingress_service_annotations` (the
   `aws-load-balancer-ssl-cert` / `-ssl-ports` / `-backend-protocol`
   annotations) for the chart's Service.
2. Install the chart, read the Service's load balancer hostname, and apply again
   with `ingress_load_balancer_hostname`. The module creates the CNAME, and
   `honua_url` becomes `https://<domain_name>`. Destroy removes the record.

`domain_name` can be any hostname in a Route 53 zone you own; nothing assumes a
particular DNS suffix. From the first apply, `chart_config_env` (and
`honua_server_environment`) carry `Public__BaseUrl = https://<domain_name>`:
honua-server builds absolute links (publication URLs, OGC and STAC self links,
admin OIDC redirect URIs) only from `Public:BaseUrl`, never from the request
`Host`, and the chart defaults `config.env.Public__BaseUrl` to `""`. Set
`public_base_url` instead when clients reach the chart through your own
ingress or CDN host (for example `https://maps.example.com`); it must be an
absolute `http`/`https` URL because the server ignores a bare host name. Do not
also set `config.env.Public__BaseUrl` in the chart values. The `public_base_url`
output reports the rendered value.

## Secret encryption

By default the module mints a KMS CMK and uses it to envelope-encrypt Kubernetes
secrets — the production shape. That is the wrong default for a cluster that
lives for an hour: `terraform destroy` can only *schedule* a CMK for deletion,
7 days is the shortest window AWS accepts, and the key bills the whole time
(honua-release#127). Two knobs:

- `cluster_secret_encryption_enabled = false` — no CMK is created and no
  `encryption_config` is set. Use this for ephemeral parity/validation cells,
  which certify nothing about envelope encryption.
- `cluster_secret_encryption_key_arn = "arn:aws:kms:..."` — encrypt with a
  long-lived key created once and never destroyed. Use this instead when the
  cells *are* meant to keep the encryption path under test.

## Example

```hcl
module "eks" {
  source = "../../modules/aws-eks"

  name_prefix = "honua"
  environment = "it"
}
```

## Database connection sizing

honua-server sizes every Npgsql pool from `Limits:Connections`, and its
defaults are generous: `MaxConnectionPoolSize` 200 and `MinConnectionPoolSize`
20 per pool. Each server process opens at least two pools on the database
(the main data source, and the pool keyed by its connection string that the
publish, import and migration paths open directly; each bound secure
connection adds one more). Left at the defaults, a few processes exhaust a
small database with PostgreSQL `53300` (on the public demo the FeatureServer
then answered `Query execution failed` inside HTTP 200).

The module sizes the pools from its own inputs (`db-pool-sizing.tf`; the
shared block is identical in `aws-serverless`, `aws-ecs`, `aws-eks`,
`azure-aca` and `azure-functions`):

```
usable           = max_connections - reserved
per_process_pool = floor((floor(usable x db_connection_safety_fraction) - other_connections)
                         / (max_processes x db_pools_per_process))
                   clamped to [1, 200]
```

and renders `Limits__Connections__MaxConnectionPoolSize` and
`Limits__Connections__MaxConcurrentQueries` (equal: the server refuses to
start when the query limit exceeds the pool), plus `MinConnectionPoolSize` (`min(20, pool)`). `max_connections` comes from
a table, or `db_max_connections_override`:

- **RDS for PostgreSQL**: `LEAST({DBInstanceClassMemory/9531392}, 5000)`
  ([RDS limits](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html#RDS_Limits.MaxConnections)),
  computed from 75% of the class's nominal memory because
  `DBInstanceClassMemory` excludes what the OS and RDS keep (observed:
  `db.t3.micro` 87 and `db.t4g.small` about 180, the table gives 84 and 168).
  Families t3/t4g, m5/m6g/m6i/m7g/m7i and r5/r6g/r6i/r7g/r7i; 5 reserved
  (`superuser_reserved_connections` 3 + `rds.rds_superuser_reserved_connections` 2).
  Aurora is not provisioned by these modules.
- **Azure Database for PostgreSQL flexible server**: the documented default per
  SKU ([limits](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-limits#maximum-connections)),
  `B_Standard_B1ms` 50 up to 5000; 15 reserved.

| Input | Default | Meaning |
|-------|---------|---------|
| `server_max_replicas` | `null` | The chart's replica ceiling (replicas or HPA `maxReplicas`). Null renders no pool keys. |
| `db_pool_size_override` | `null` | Pool size to render instead of the derived one. |
| `db_connection_pooler_enabled` | `false` | The server reaches PostgreSQL through a pooler; skips the budget check. |
| `db_max_connections_override` | `null` | `max_connections` to size from (custom parameter, a class/SKU missing from the table, or an existing database). |
| `db_pools_per_process` | `2` | Pools each server process opens. |
| `db_connection_safety_fraction` | `0.85` | Share of the usable connections the server pools may take; the rest is for migrations, bootstrap and operator sessions. |

`plan` fails (a precondition on the `db_connection_budget` output) when
`max_processes x db_pools_per_process x pool + other_connections` exceeds the
usable connections, unless `db_connection_pooler_enabled`. The derived pool only fails it when even a pool of 1
does not fit; an override that is too large always does. The
`db_connection_budget` output reports every term and `source`: `derived`,
`override`, `fallback` (the module's previous value) or `server-default` (no
keys rendered). Sizing needs a known `max_connections` and a bounded process
count; without either the module renders what it rendered before.

**Processes.** The Helm chart owns the replica count, so sizing is opt-in:
set `server_max_replicas` and the keys join `chart_config_env` and
`honua_server_environment`. The worst case adds the Deployment's default
`maxSurge` of 25% (`server_max_replicas + ceil(server_max_replicas x 0.25)`).

**Example.** `db.t3.micro` with `server_max_replicas = 4`: 5 processes,
`67 / (5 x 2) = 6` per pool (worst case 60 of 79 usable).

**Upgrade note.** With `server_max_replicas` unset nothing changes.

## Redis connections

Redis needs no pool formula: each server process holds one StackExchange.Redis
multiplexer for infrastructure (events, coordination) and a second one for the
distributed cache when that is enabled, about two sockets each, so roughly
**4 connections per process** whatever the request concurrency. Budget
`max processes x 4` against the Redis server's client limit. ElastiCache for Redis allows 65,000 client connections per node (`maxclients`, not configurable). In a non-Development environment with Redis configured the server requires durable distributed events, so Redis is a hard startup dependency for every pod.

The server forces only `abortConnect=false`, `connectRetry>=3` and an
exponential reconnect policy; timeouts come from the connection string. The
string this module builds therefore ends with
`,connectTimeout=5000,syncTimeout=10000,keepAlive=60`
(`redis_connect_timeout_ms`, `redis_sync_timeout_ms`,
`redis_keep_alive_seconds`); the 5000 ms `syncTimeout` default has timed out
under load (honua-server PR #4967). It is stored in the connection secret, not
in the process environment. A caller-supplied `redis_connection_string` is used
unchanged. Existing deployments see an in-place update of that secret.

## Outputs

Cluster configuration: `environment`, `cluster_name`, `cluster_arn`,
`cluster_endpoint`, `cluster_certificate_authority_data`, `vpc_id`,
`oidc_provider_arn` (null under `pod_identity`), `oidc_provider`,
`cluster_security_group_id`, `node_security_group_id`,
`control_plane_target_kind = "Kubernetes"`,
`control_plane_backend_name = "honua-kubernetes-deployment"`,
`control_plane_telemetry_policy = "kubernetes-honua-http"`,
`honua_metrics_target = "honua"`.

The backend hint selects Honua's native Kubernetes Deployment adapter. It does
not register a deploy target or verify a workload. The module installs no Argo
resources. It requires a compatible Server artifact implementing the native
backend; older artifacts that only support the legacy backend cannot consume
this hint. Do not substitute an Argo adapter. An installed handoff additionally needs the actual Deployment,
Service and public route, current resource identities, and verified serving
health. The native workload producer and v2 handoff are tracked in
[IaC267](https://github.com/honua-io/honua-iac/issues/267); these cluster outputs
alone do not complete that installation.

GA cell handoff:

| Output | Consumer |
| --- | --- |
| `aws_region`, `private_subnet_ids`, `public_subnet_ids` | harness |
| `workload_identity_mode`, `kubernetes_namespace`, `server_service_account_name`, `server_role_arn`, `server_service_account_annotations` | chart server service account |
| `gp_job_namespace`, `gp_job_service_account_name`, `gp_job_image`, `gp_job_role_arn`, `gp_job_service_account_annotations`, `gp_job_data_bucket_arn` | chart GP Job service account / RBAC |
| `control_plane_kubernetes_environment`, `operations_policy_environment`, `honua_server_environment` | chart `env` |
| `database_managed`, `db_endpoint`, `db_connection_secret_arn`, `admin_password_secret_arn`, `master_key_secret_arn`, `postgis_enabled` | harness / operator |
| `redis_enabled`, `redis_endpoint`, `redis_connection_secret_arn`, `operation_key_ring_certificate_secret_arn`, `audit_chain_key_secret_arn` | harness / operator |
| `domain_name`, `ingress_certificate_arn`, `ingress_service_annotations`, `domain_record_managed`, `honua_url` | chart Service, harness |
| `chart_config_env`, `certificate_arn` (= `ingress_certificate_arn`), `db_connection_string` (sensitive), `redis_connection_string` (sensitive) | release harness (`e2e/targets/aws_eks.py`) |
