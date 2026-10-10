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

Pod Identity is the default because an IAM OIDC provider is an account-level
object: the release account's cell guardrail denies `iam:*OpenIDConnectProvider*`
outright, which is half of why e2e-cloud-aws run 38057015781 never provisioned
an EKS cell. The other half was the node-group role: the upstream default name
`default-eks-node-group-*` falls outside the cell's IAM name prefix, so the role
is now named under `<name_prefix>-<environment>`. Both workload roles are too.

Both roles read every runtime secret in play (database, admin password, master
key, Redis, the key-ring certificate when Redis is on, the audit-chain key when
supplied) and decrypt any customer-managed KMS key given for them. With
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
| `redis_enabled` | `false` | ElastiCache Redis; requires the key-ring certificate. |
| `redis_auth_token`, `redis_node_type`, `redis_engine_version`, `redis_parameter_group_name`, `redis_num_cache_clusters`, `redis_port` | generated, `cache.t3.micro`, `7.0`, `default.redis7`, 1, 6379 | Redis shape. |
| `operation_key_ring_certificate_secret_arn` / `_kms_key_arn` | `""` | Operator-owned PKCS#12 bundle; required with Redis. Only the ARN enters Terraform. |
| `audit_chain_key_secret_arn` / `_kms_key_arn` | `""` | Operator-owned audit hash-chain key; recommended (a check warns when empty). |
| `operations_policy_rules` | `[]` | Ordered first-match-wins rules, same shape as aws-ecs; rendered as `Operations__Policy__Rules__<n>__<Field>`. Production denies every typed operation until a rule allows it. |
| `domain_name` / `route53_zone_id` | `""` | Set together: DNS-validated ACM certificate. |
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

## Outputs

Cluster (unchanged): `environment`, `cluster_name`, `cluster_arn`,
`cluster_endpoint`, `cluster_certificate_authority_data`, `vpc_id`,
`oidc_provider_arn` (null under `pod_identity`), `oidc_provider`,
`cluster_security_group_id`, `node_security_group_id`,
`control_plane_target_kind = "Kubernetes"`,
`control_plane_backend_name = "honua-gitops-kubernetes"`,
`control_plane_telemetry_policy = "kubernetes-honua-http"`,
`honua_metrics_target = "honua"`.

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
