output "autoscaling_group_name" {
  description = "Set desired capacity to one to wake the build host, zero to stop it."
  value       = aws_autoscaling_group.build.name
}

output "instance_lookup_filters" {
  description = "Stable EC2 filters for the current host; poll running instances and refresh the SSH address after replacement."
  value = [
    { Name = "tag:aws:autoscaling:groupName", Values = [aws_autoscaling_group.build.name] },
    { Name = "instance-state-name", Values = ["running"] }
  ]
}
