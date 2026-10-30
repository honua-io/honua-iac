# Custom domain for the Honua endpoint.
#
# The Helm chart, not Terraform, creates the load balancer (a LoadBalancer
# Service), so this module owns the two pieces that do not depend on it:
#   1. the ACM certificate for domain_name, DNS-validated in route53_zone_id —
#      handed to the chart as the Service's TLS annotations
#      (ingress_service_annotations);
#   2. the Route53 record pointing domain_name at the load balancer, created
#      once the caller feeds the load balancer's DNS name back in
#      (ingress_load_balancer_hostname) on a second apply. Terraform then owns
#      the record and removes it on destroy, so no DNS outlives the cluster.

locals {
  use_managed_cert    = var.domain_name != "" && var.route53_zone_id != ""
  create_domain_alias = local.use_managed_cert && var.ingress_load_balancer_hostname != ""
  certificate_arn     = local.use_managed_cert ? aws_acm_certificate_validation.this[0].certificate_arn : ""

  # Annotations for the chart's LoadBalancer Service: TLS on 443 with the
  # managed certificate, plain HTTP to the pods. Understood by both the in-tree
  # cloud provider and the AWS Load Balancer Controller. chart_config_env sets
  # SecurityHeaders__HstsHttpsOnly=false for this hop (handoff.tf): the server
  # would otherwise omit Strict-Transport-Security because it sees HTTP.
  ingress_service_annotations = local.use_managed_cert ? {
    "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"         = local.certificate_arn
    "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"        = "443"
    "service.beta.kubernetes.io/aws-load-balancer-backend-protocol" = "http"
  } : {}
}

check "domain_inputs_paired" {
  assert {
    condition     = (var.domain_name == "") == (var.route53_zone_id == "")
    error_message = "domain_name and route53_zone_id must be set together; with only one of them no certificate or DNS record is managed."
  }
}

resource "aws_acm_certificate" "this" {
  count                     = local.use_managed_cert ? 1 : 0
  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"
  tags                      = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

# Keyed on the requested names (known at plan) rather than on
# domain_validation_options, which is only known after the certificate exists.
resource "aws_route53_record" "cert_validation" {
  for_each = local.use_managed_cert ? toset(concat([var.domain_name], var.subject_alternative_names)) : toset([])

  zone_id         = var.route53_zone_id
  name            = one([for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.resource_record_name if dvo.domain_name == each.key])
  type            = one([for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.resource_record_type if dvo.domain_name == each.key])
  records         = [one([for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.resource_record_value if dvo.domain_name == each.key])]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count                   = local.use_managed_cert ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_route53_record" "service_alias" {
  count   = local.create_domain_alias ? 1 : 0
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "CNAME"
  ttl     = 60
  records = [var.ingress_load_balancer_hostname]
}
