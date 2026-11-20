# A Route 53 zone for proving Launch Stack domain installs (custom viewer names, HTTPS to the load balancer) on gate
# stacks. Empty gate_test_domain creates nothing. The zone carries no records of its own beyond what Route 53 adds;
# gate stacks write their validation and alias records through the service role only (shared-account.tf).
resource "aws_route53_zone" "gate_test" {
  count   = var.gate_test_domain == "" ? 0 : 1
  name    = var.gate_test_domain
  comment = "Gate test stacks only; records are written by HonuaGateCloudFormation."
  # Only gate records live here, and stacks that fail to delete can leave some behind.
  force_destroy = true
  tags          = { HonuaGate = "true", Purpose = "gate-test-domain" }
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

# The service role may only read the test zone and change its ordinary records: no zone deletion, tags, DNSSEC,
# query logging or comment changes, and no NS, SOA or DS records (apex or sub-delegation). In the attached fences
# policy, because the inline service policy is near its quota.
locals {
  gate_test_zone_denies = [for arn in aws_route53_zone.gate_test[*].arn : [{
    Sid       = "GateTestZoneRecordsOnly", Effect = "Deny", Resource = arn
    NotAction = ["route53:ChangeResourceRecordSets", "route53:Get*", "route53:List*"]
    }, {
    Sid       = "GateTestZoneRecordTypes", Effect = "Deny", Action = "route53:ChangeResourceRecordSets", Resource = arn
    Condition = { "ForAnyValue:StringEquals" = { "route53:ChangeResourceRecordSetsRecordTypes" = ["NS", "SOA", "DS"] } }
  }]]
}
