output "source_instance_id" {
  description = "Source instance in the primary Region"
  value       = aws_instance.source.id
}

output "backup_ami_id" {
  description = "AMI of the source instance, in the primary Region"
  value       = aws_ami_from_instance.backup.id
}

output "copy_ami_id" {
  description = "Copy of the AMI in the secondary Region"
  value       = aws_ami_copy.secondary.id
}

output "restored_instance_id" {
  description = "Instance launched from the copy in the secondary Region (null when restore = false)"
  value       = try(aws_instance.restored[0].id, null)
}

output "images_command" {
  description = "Shows both AMIs and their snapshots"
  value       = <<-EOT
    aws ec2 describe-images ${local.primary_flags} --image-ids ${aws_ami_from_instance.backup.id} \
      --query 'Images[0].[ImageId,State,BlockDeviceMappings[0].Ebs.SnapshotId,BlockDeviceMappings[0].Ebs.Encrypted]' --output text
    aws ec2 describe-images ${local.secondary_flags} --image-ids ${aws_ami_copy.secondary.id} \
      --query 'Images[0].[ImageId,State,BlockDeviceMappings[0].Ebs.SnapshotId,BlockDeviceMappings[0].Ebs.Encrypted]' --output text
  EOT
}

output "check_source_command" {
  description = "On the source instance: prints the marker and where it runs"
  value       = <<-EOT
    CMD=$(aws ssm send-command ${local.primary_flags} --instance-ids ${aws_instance.source.id} \
      --document-name AWS-RunShellScript --parameters '${local.check_commands}' \
      --query Command.CommandId --output text)
    aws ssm wait command-executed ${local.primary_flags} --command-id "$CMD" --instance-id ${aws_instance.source.id} || true
    aws ssm get-command-invocation ${local.primary_flags} --command-id "$CMD" --instance-id ${aws_instance.source.id} \
      --query StandardOutputContent --output text
  EOT
}

output "check_restored_command" {
  description = "On the restored instance: the marker still names the source instance and Region"
  value       = <<-EOT
    CMD=$(aws ssm send-command ${local.secondary_flags} --instance-ids ${local.restored_id} \
      --document-name AWS-RunShellScript --parameters '${local.check_commands}' \
      --query Command.CommandId --output text)
    aws ssm wait command-executed ${local.secondary_flags} --command-id "$CMD" --instance-id ${local.restored_id} || true
    aws ssm get-command-invocation ${local.secondary_flags} --command-id "$CMD" --instance-id ${local.restored_id} \
      --query StandardOutputContent --output text
  EOT
}
