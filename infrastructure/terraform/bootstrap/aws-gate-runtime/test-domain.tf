# A Route 53 zone for proving Launch Stack domain installs (custom viewer names, HTTPS to the load balancer) on gate
# stacks. Empty gate_test_domain creates nothing. The zone carries no records of its own beyond what Route 53 adds;
# gate stacks write their validation and alias records through the service role only (shared-account.tf).
resource "aws_route53_zone" "gate_test" {
  count   = var.gate_test_domain == "" ? 0 : 1
  name    = var.gate_test_domain
  comment = "Gate test stacks only; records are written by HonuaGateCloudFormation."
  tags    = { HonuaGate = "true", Purpose = "gate-test-domain" }
}

# Delegation from a parent zone in this account, when main names one; otherwise delegate by hand from the
# gate_test_name_servers output.
resource "aws_route53_record" "gate_test_delegation" {
  count   = var.gate_test_domain != "" && var.gate_test_parent_zone_id != "" ? 1 : 0
  zone_id = var.gate_test_parent_zone_id
  name    = var.gate_test_domain
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.gate_test[0].name_servers
}

output "gate_test_zone_id" {
  value       = one(aws_route53_zone.gate_test[*].zone_id)
  description = "HostedZoneId for gate stacks that install with DomainNames under gate_test_domain."
}

output "gate_test_name_servers" {
  value       = one(aws_route53_zone.gate_test[*].name_servers)
  description = "Name servers to delegate gate_test_domain to when the parent zone is not in this account."
}
