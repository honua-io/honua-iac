output "instance_id" { value = aws_instance.build.id }
output "ssh_config" {
  description = "Append to your SSH configuration and set IdentityFile. The public address changes after each stop and start; refresh it with aws ec2 describe-instances."
  value       = <<-EOT
    Host honua-build
      HostName ${aws_instance.build.public_dns}
      User ubuntu
      IdentitiesOnly yes
  EOT
}
