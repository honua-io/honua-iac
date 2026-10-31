output "host_public_ips" { value = aws_instance.eval[*].public_ip }
output "host_public_dns" { value = aws_instance.eval[*].public_dns }
output "ssh_config" {
  description = "Append to your SSH configuration; set IdentityFile to the corresponding private key."
  value = join("\n", [for i, host in aws_instance.eval : <<-EOT
    Host honua-eval-${i + 1}
      HostName ${host.public_ip}
      User ubuntu
      IdentitiesOnly yes
  EOT
  ])
}
