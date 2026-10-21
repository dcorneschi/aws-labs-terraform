output "asg_name" {
  description = "Name of the Auto Scaling group"
  value       = aws_autoscaling_group.this.name
}

output "launch_template_id" {
  value = aws_launch_template.this.id
}

output "ami_id" {
  description = "The Amazon Linux 2023 image used (it changes over time)"
  value       = data.aws_ssm_parameter.al2023.value
  sensitive   = true
}

output "list_instances_command" {
  description = "Shows the instances in the group, and whether each is Spot or On-Demand"
  value       = <<-EOT
    aws ec2 describe-instances ${local.aws_flags} \
      --filters Name=tag:Name,Values=${var.name} Name=instance-state-name,Values=pending,running \
      --query 'Reservations[].Instances[].[InstanceId,InstanceType,Placement.AvailabilityZone,InstanceLifecycle]' --output table
  EOT
}

output "instance_ids" {
  description = "IDs of the running instances in the group (empty until the group has launched them: run terraform apply -refresh-only)"
  value       = data.aws_instances.group.ids
}

output "burn_command" {
  description = "Keeps the CPU of the first instance at 100% for 15 minutes. Shows <instance-id> until the group has launched an instance"
  value       = <<-EOT
    aws ssm send-command ${local.aws_flags} --instance-ids ${local.first_instance_id} \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["/usr/local/bin/burn.sh 900"]' \
      --query Command.CommandId --output text
  EOT
}

output "watch_commands" {
  value = <<-EOT
    aws autoscaling describe-scaling-activities ${local.aws_flags} --auto-scaling-group-name ${aws_autoscaling_group.this.name} --max-items 5 --query 'Activities[].[StartTime,StatusCode,Description]' --output table
    aws cloudwatch describe-alarms ${local.aws_flags} --alarm-names ${aws_cloudwatch_metric_alarm.cpu_high.alarm_name} --query 'MetricAlarms[0].[StateValue,StateReason]' --output text
  EOT
}
