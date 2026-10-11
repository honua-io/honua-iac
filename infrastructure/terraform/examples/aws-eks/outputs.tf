# GA cell handoff: what the honua-helm chart and the release harness read after
# apply. The pre-existing outputs (cluster_name, cluster_arn, ...) stay in
# main.tf unchanged.

output "aws_region" {
  description = "Region the cluster runs in."
  value       = module.eks.aws_region
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded EKS cluster CA data."
  value       = module.eks.cluster_certificate_authority_data
}

output "node_security_group_id" {
  description = "Security group of the managed nodes (and therefore of the pods)."
  value       = module.eks.node_security_group_id
}

output "workload_identity_mode" {
  description = "pod_identity or irsa; under irsa the chart must apply the *_service_account_annotations."
  value       = module.eks.workload_identity_mode
}

output "kubernetes_namespace" {
  description = "Namespace the Helm release must be installed into."
  value       = module.eks.kubernetes_namespace
}

output "server_service_account_name" {
  description = "Chart serviceAccount.name for the server pods."
  value       = module.eks.server_service_account_name
}

output "server_role_arn" {
  description = "IAM role the server pods assume."
  value       = module.eks.server_role_arn
}

output "server_service_account_annotations" {
  description = "Chart serviceAccount.annotations (empty under pod_identity)."
  value       = module.eks.server_service_account_annotations
}

output "gp_job_namespace" {
  description = "ControlPlane:Kubernetes:DefaultNamespace."
  value       = module.eks.gp_job_namespace
}

output "gp_job_service_account_name" {
  description = "ControlPlane:Kubernetes:DefaultServiceAccount."
  value       = module.eks.gp_job_service_account_name
}

output "gp_job_image" {
  description = "ControlPlane:Kubernetes:DefaultImage (empty when not set)."
  value       = module.eks.gp_job_image
}

output "gp_job_role_arn" {
  description = "IAM role GP Job pods assume."
  value       = module.eks.gp_job_role_arn
}

output "gp_job_service_account_annotations" {
  description = "Annotations for the GP job service account (empty under pod_identity)."
  value       = module.eks.gp_job_service_account_annotations
}

output "gp_job_data_bucket_arn" {
  description = "S3 bucket the GP job and server roles may use (empty when not enabled)."
  value       = module.eks.gp_job_data_bucket_arn
}

output "control_plane_kubernetes_environment" {
  description = "ControlPlane__Kubernetes__* entries for the server."
  value       = module.eks.control_plane_kubernetes_environment
}

output "operations_policy_environment" {
  description = "Operations__Policy__Rules__<n>__<Field> entries rendered from operations_policy_rules."
  value       = module.eks.operations_policy_environment
}

output "honua_server_environment" {
  description = "Server environment for the chart's env values: aws:secretsmanager:<arn> references, operation policy rules and ControlPlane:Kubernetes defaults. ARNs only, never secret values."
  value       = module.eks.honua_server_environment
}

output "database_managed" {
  description = "Whether the root manages RDS."
  value       = module.eks.database_managed
}

output "db_endpoint" {
  description = "PostgreSQL endpoint address."
  value       = module.eks.db_endpoint
}

output "db_connection_secret_arn" {
  description = "Secrets Manager ARN of the database connection string."
  value       = module.eks.db_connection_secret_arn
}

output "admin_password_secret_arn" {
  description = "Secrets Manager ARN of the bootstrap admin password."
  value       = module.eks.admin_password_secret_arn
}

output "master_key_secret_arn" {
  description = "Secrets Manager ARN of the connection-encryption master key."
  value       = module.eks.master_key_secret_arn
}

output "postgis_enabled" {
  description = "Whether apply ran the PostGIS bootstrap."
  value       = module.eks.postgis_enabled
}

output "redis_enabled" {
  description = "Whether ElastiCache Redis is provisioned."
  value       = module.eks.redis_enabled
}

output "redis_endpoint" {
  description = "ElastiCache primary endpoint (empty when Redis is off)."
  value       = module.eks.redis_endpoint
}

output "redis_connection_secret_arn" {
  description = "Secrets Manager ARN of the Redis connection string (empty when Redis is off)."
  value       = module.eks.redis_connection_secret_arn
}

output "operation_key_ring_certificate_secret_arn" {
  description = "Key-ring certificate secret ARN the workload roles read (empty when Redis is off)."
  value       = module.eks.operation_key_ring_certificate_secret_arn
}

output "audit_chain_key_secret_arn" {
  description = "Audit-chain key secret ARN the workload roles read."
  value       = module.eks.audit_chain_key_secret_arn
}

output "domain_name" {
  description = "Custom hostname (empty without domain_name + route53_zone_id)."
  value       = module.eks.domain_name
}

output "ingress_certificate_arn" {
  description = "Validated ACM certificate for domain_name."
  value       = module.eks.ingress_certificate_arn
}

output "ingress_service_annotations" {
  description = "Chart service.annotations that terminate TLS on 443 with ingress_certificate_arn."
  value       = module.eks.ingress_service_annotations
}

output "domain_record_managed" {
  description = "Whether the Route53 record for domain_name exists (after the second apply with ingress_load_balancer_hostname)."
  value       = module.eks.domain_record_managed
}

output "honua_url" {
  description = "https://<domain_name> once the domain record is managed; empty before (use the chart load balancer hostname)."
  value       = module.eks.honua_url
}

# --- Release harness contract (honua-release e2e/targets/aws_eks.py) --------------

output "chart_config_env" {
  description = "Non-credential server environment for the chart's config.env (ControlPlane__Kubernetes__*, policy rules, CORS, operator secret references)."
  value       = module.eks.chart_config_env
}

output "certificate_arn" {
  description = "Validated ACM certificate ARN for domain_name; the chart's Service terminates TLS with it."
  value       = module.eks.certificate_arn
}

output "db_connection_string" {
  description = "Database connection string, for the chart's Secret."
  value       = module.eks.db_connection_string
  sensitive   = true
}

output "redis_connection_string" {
  description = "Redis connection string, for the chart's Secret. Empty when Redis is off."
  value       = module.eks.redis_connection_string
  sensitive   = true
}
