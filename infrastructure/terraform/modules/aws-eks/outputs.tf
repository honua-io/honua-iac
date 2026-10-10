output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "environment" {
  description = "Deployment environment label used for control-plane target IDs."
  value       = var.environment
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded EKS cluster CA data."
  value       = module.eks.cluster_certificate_authority_data
}

output "vpc_id" {
  description = "VPC ID used by the EKS cluster."
  value       = module.vpc.vpc_id
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for IRSA. Null unless workload_identity_mode is irsa (the default pod_identity mode needs no OIDC provider)."
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider" {
  description = "OIDC provider URL (without https://)."
  value       = module.eks.oidc_provider
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID attached to EKS managed node groups."
  value       = module.eks.node_security_group_id
}

output "control_plane_target_kind" {
  description = "Honua control-plane deploy target kind for this cluster."
  value       = "Kubernetes"
}

output "control_plane_backend_name" {
  description = "Honua control-plane deploy backend name for Kubernetes GitOps."
  value       = "honua-gitops-kubernetes"
}

output "control_plane_telemetry_policy" {
  description = "Default Honua telemetry policy for Kubernetes deploy health evaluation."
  value       = "kubernetes-honua-http"
}

output "honua_metrics_target" {
  description = "Default Honua workload name hint used by the standard Helm deployment."
  value       = "honua"
}

output "aws_region" {
  description = "Region the cluster runs in."
  value       = data.aws_region.current.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (nodes, Redis, private RDS)."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs (internet-facing load balancers, publicly accessible validation RDS)."
  value       = module.vpc.public_subnets
}

# --- Workload identity / GP on Kubernetes handoff ---------------------------------

output "workload_identity_mode" {
  description = "pod_identity (roles bound by EKS Pod Identity associations; service accounts need no annotation) or irsa (service accounts need the *_service_account_annotations)."
  value       = var.workload_identity_mode
}

output "kubernetes_namespace" {
  description = "Namespace the Helm release must be installed into for the server role binding to apply."
  value       = var.kubernetes_namespace
}

output "server_service_account_name" {
  description = "Service account the chart's server pods must run as (chart serviceAccount.name)."
  value       = var.server_service_account_name
}

output "server_role_arn" {
  description = "IAM role the server pods assume (Secrets Manager reads for honua_server_environment; GP data bucket when enabled)."
  value       = aws_iam_role.workload["server"].arn
}

output "server_service_account_annotations" {
  description = "Annotations for the chart's server service account (serviceAccount.annotations). Empty under pod_identity."
  value       = local.workload_service_account_annotations["server"]
}

output "gp_job_namespace" {
  description = "Namespace GP Kubernetes Jobs run in (ControlPlane:Kubernetes:DefaultNamespace)."
  value       = local.gp_job_namespace
}

output "gp_job_service_account_name" {
  description = "Service account GP Jobs run as (ControlPlane:Kubernetes:DefaultServiceAccount); the chart creates it."
  value       = var.gp_job_service_account_name
}

output "gp_job_image" {
  description = "Image GP Kubernetes Jobs run (ControlPlane:Kubernetes:DefaultImage). Empty when not set."
  value       = var.gp_job_image
}

output "gp_job_role_arn" {
  description = "IAM role GP Job pods assume (same runtime secret reads as the server, plus the GP data bucket when enabled)."
  value       = aws_iam_role.workload["gp-job"].arn
}

output "gp_job_service_account_annotations" {
  description = "Annotations for the GP job service account. Empty under pod_identity."
  value       = local.workload_service_account_annotations["gp-job"]
}

output "gp_job_data_bucket_arn" {
  description = "S3 bucket the GP job and server roles may read and write. Empty when gp_job_data_bucket_enabled is false."
  value       = var.gp_job_data_bucket_enabled ? var.gp_job_data_bucket_arn : ""
}

output "control_plane_kubernetes_environment" {
  description = "ControlPlane__Kubernetes__{DefaultNamespace,DefaultServiceAccount,DefaultImage} entries for the server (DefaultImage only when gp_job_image is set). Also merged into honua_server_environment."
  value       = local.control_plane_kubernetes_environment
}

output "operations_policy_environment" {
  description = "The Operations__Policy__Rules__<n>__<Field> entries rendered from operations_policy_rules. Empty when no rules are set. Also merged into honua_server_environment."
  value       = local.operations_policy_environment
}

output "honua_server_environment" {
  description = "Server environment for the chart's env values: aws:secretsmanager:<arn> references (database, admin password, master key, Redis, key ring, audit-chain key) resolved by the server with its workload role, the operation policy rules, and the ControlPlane:Kubernetes defaults. Contains ARNs, never secret values."
  value       = local.honua_server_environment
}

# --- Data plane -------------------------------------------------------------------

output "database_managed" {
  description = "Whether this module manages the RDS instance (false when existing_db_* are supplied)."
  value       = !local.db_use_existing
}

output "db_endpoint" {
  description = "PostgreSQL endpoint address."
  value       = local.db_endpoint
}

output "db_connection_secret_arn" {
  description = "Secrets Manager ARN holding the Npgsql connection string (ConnectionStrings:DefaultConnection)."
  value       = aws_secretsmanager_secret.db_connection.arn
}

output "admin_password_secret_arn" {
  description = "Secrets Manager ARN holding the bootstrap admin password (HONUA_ADMIN_PASSWORD)."
  value       = aws_secretsmanager_secret.admin_password.arn
}

output "master_key_secret_arn" {
  description = "Secrets Manager ARN holding the connection-encryption master key (Security:ConnectionEncryption:MasterKey)."
  value       = aws_secretsmanager_secret.master_key.arn
}

output "postgis_enabled" {
  description = "Whether apply ran the PostGIS bootstrap on the managed database."
  value       = length(null_resource.enable_postgis) > 0
}

output "redis_enabled" {
  description = "Whether the module provisioned ElastiCache Redis."
  value       = var.redis_enabled
}

output "redis_endpoint" {
  description = "ElastiCache primary endpoint address. Empty when Redis is off."
  value       = var.redis_enabled ? aws_elasticache_replication_group.redis[0].primary_endpoint_address : ""
}

output "redis_connection_secret_arn" {
  description = "Secrets Manager ARN holding the Redis connection string (ConnectionStrings:redis; TLS + AUTH). Empty when Redis is off."
  value       = var.redis_enabled ? aws_secretsmanager_secret.redis_connection[0].arn : ""
}

output "operation_key_ring_certificate_secret_arn" {
  description = "Operator-owned key-ring certificate secret ARN the workload roles may read. Empty when Redis is off."
  value       = var.redis_enabled ? var.operation_key_ring_certificate_secret_arn : ""
}

output "audit_chain_key_secret_arn" {
  description = "Operator-owned audit hash-chain key secret ARN the workload roles may read. Empty when not supplied."
  value       = var.audit_chain_key_secret_arn
}

# --- Custom domain ----------------------------------------------------------------

output "domain_name" {
  description = "Custom hostname, when domain_name and route53_zone_id are set. Empty otherwise."
  value       = local.use_managed_cert ? var.domain_name : ""
}

output "ingress_certificate_arn" {
  description = "Validated ACM certificate ARN for domain_name. Empty without a managed domain."
  value       = local.certificate_arn
}

output "ingress_service_annotations" {
  description = "Annotations for the chart's LoadBalancer Service (service.annotations) that terminate TLS on 443 with ingress_certificate_arn. Empty without a managed domain."
  value       = local.ingress_service_annotations
}

output "domain_record_managed" {
  description = "Whether the Route53 record pointing domain_name at ingress_load_balancer_hostname exists (second apply)."
  value       = local.create_domain_alias
}

output "honua_url" {
  description = "https://<domain_name> once the domain record is managed; empty until then (the chart's load balancer DNS name is the endpoint before that)."
  value       = local.create_domain_alias ? "https://${var.domain_name}" : ""
}
