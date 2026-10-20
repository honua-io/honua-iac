# Configured resources from this exact Terraform state. A verifier must read
# fresh Kubernetes, AWS load balancer and DNS facts before a runtime handoff.
locals {
  resource_identity = merge({
    clusterArn                     = data.aws_eks_cluster.selected.arn
    apiServer                      = data.aws_eks_cluster.selected.endpoint
    caSha256                       = data.external.cluster_ca.result.sha256
    namespace                      = kubernetes_namespace_v1.honua.metadata[0].name
    deploymentName                 = kubernetes_deployment_v1.honua.metadata[0].name
    containerName                  = var.container_name
    serviceName                    = kubernetes_service_v1.public.metadata[0].name
    servicePort                    = "443"
    targetPort                     = "8080"
    routeKind                      = "LoadBalancerService"
    routeName                      = kubernetes_service_v1.public.metadata[0].name
    routeHost                      = var.public_hostname
    publicUrl                      = local.public_url
    certificateArn                 = var.certificate_arn
    serverServiceAccountName       = kubernetes_service_account_v1.server.metadata[0].name
    serverRoleArn                  = var.server_role_arn
    serverPodIdentityAssociationId = data.external.server_association.result.association_id
    gpServiceAccountName           = kubernetes_service_account_v1.gp_job.metadata[0].name
    gpRoleArn                      = var.gp_job_role_arn
    gpPodIdentityAssociationId     = data.external.gp_job_association.result.association_id
    dbConnectionSecretArn          = var.db_connection_secret_arn
    adminPasswordSecretArn         = var.admin_password_secret_arn
    masterKeySecretArn             = var.master_key_secret_arn
    }, var.route53_zone_id == "" ? {} : {
    dnsZoneId     = aws_route53_record.public[0].zone_id
    dnsRecordName = aws_route53_record.public[0].fqdn
  })
}

output "runtime_binding_contract" {
  description = "honua.runtime-binding/v1 configured resource identity after apply. It is not a live observation, serving digest, readiness or authorization receipt."
  value = {
    schemaVersion = "honua.runtime-binding/v1"
    runtimeKind   = "aws-eks"
    targetKind    = "Kubernetes"
    backend       = "honua-kubernetes-deployment"
    targetId      = var.target_id
    environment   = var.environment
    platform = {
      accountId = data.aws_caller_identity.current.account_id
      region    = var.region
      partition = data.aws_partition.current.partition
    }
    resourceIdentity = local.resource_identity
  }
}

output "configured_install" {
  description = "Non-authoritative install inventory; external-DNS mode is unqualified until a trusted route is observed."
  value = {
    status                 = "configured"
    tenant_id              = var.tenant_id
    image_reference        = kubernetes_deployment_v1.honua.spec[0].template[0].spec[0].container[0].image
    image_digest           = local.server_digest
    gp_job_image_reference = var.gp_job_image_reference
    gp_job_image_digest    = local.gp_job_digest
    workload_identity_mode = var.workload_identity_mode
    load_balancer_hostname = local.lb_hostname
    public_url             = local.public_url
    route_management       = var.route53_zone_id == "" ? "external-unverified" : "route53-cname"
    resources              = local.resource_identity
    secret_refs = {
      db_connection                    = var.db_connection_secret_arn
      admin_password                   = var.admin_password_secret_arn
      connection_encryption_master_key = var.master_key_secret_arn
      redis_connection                 = var.redis_connection_secret_arn
      operation_key_ring_certificate   = var.operation_key_ring_certificate_secret_arn
      audit_chain_key                  = var.audit_chain_key_secret_arn
    }
  }
}
