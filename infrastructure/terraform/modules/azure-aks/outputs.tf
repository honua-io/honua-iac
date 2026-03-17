# --- Infrastructure outputs ---

output "resource_group_name" {
  description = "AKS resource group name."
  value       = azurerm_resource_group.this.name
}

output "environment" {
  description = "Deployment environment label used for control-plane target IDs."
  value       = var.environment
}

output "cluster_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.this.name
}

output "cluster_id" {
  description = "AKS cluster resource ID."
  value       = azurerm_kubernetes_cluster.this.id
}

output "kube_config_raw" {
  description = "Raw kubeconfig for the AKS cluster."
  value       = azurerm_kubernetes_cluster.this.kube_config_raw
  sensitive   = true
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
