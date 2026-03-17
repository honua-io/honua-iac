# --- Infrastructure outputs ---

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
  description = "ARN of the OIDC provider for IRSA."
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

# --- Honua control-plane outputs ---

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
