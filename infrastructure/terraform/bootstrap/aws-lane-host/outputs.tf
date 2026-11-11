output "instance_id" {
  description = "Stop this instance overnight and start it in the morning; the data volume and address persist."
  value       = aws_instance.lanes.id
}

output "ssh_address" {
  description = "Fixed public address for ssh ubuntu@<address>."
  value       = aws_eip.lanes.public_ip
}

output "data_volume_id" {
  description = "Persistent volume mounted at /home/ubuntu/lanes; survives instance replacement."
  value       = aws_ebs_volume.lanes.id
}
