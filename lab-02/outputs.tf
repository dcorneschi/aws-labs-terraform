output "peering_connection_id" {
  value = aws_vpc_peering_connection.a_to_b.id
}

output "vpc_a" {
  description = "VPC-A: VPC, instance and private address"
  value = {
    vpc_id         = module.vpc_a.vpc_id
    route_table_id = module.vpc_a.route_table_id
    instance_id    = module.vpc_a.instance_id
    private_ip     = module.vpc_a.private_ip
    private_dns    = module.vpc_a.private_dns
    public_dns     = module.vpc_a.public_dns
  }
}

output "vpc_b" {
  description = "VPC-B: VPC, instance and private address"
  value = {
    vpc_id         = module.vpc_b.vpc_id
    route_table_id = module.vpc_b.route_table_id
    instance_id    = module.vpc_b.instance_id
    private_ip     = module.vpc_b.private_ip
    private_dns    = module.vpc_b.private_dns
    public_dns     = module.vpc_b.public_dns
  }
}

output "peering_status_command" {
  description = "Shows the peering status (expect: active) and both CIDRs"
  value       = <<-EOT
    aws ec2 describe-vpc-peering-connections ${local.aws_flags} \
      --vpc-peering-connection-ids ${aws_vpc_peering_connection.a_to_b.id} \
      --query 'VpcPeeringConnections[0].[Status.Code,RequesterVpcInfo.CidrBlock,AccepterVpcInfo.CidrBlock]' --output text
  EOT
}

output "test_a_to_b_command" {
  description = "From the VPC-A instance: ping and HTTP to the VPC-B instance by private IP, then by public DNS name (resolves to the private IP)"
  value       = <<-EOT
    CMD=$(aws ssm send-command ${local.aws_flags} --instance-ids ${module.vpc_a.instance_id} \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["ping -c 3 ${module.vpc_b.private_ip}","curl -s -m 5 http://${module.vpc_b.private_ip}/","getent hosts ${module.vpc_b.public_dns}","curl -s -m 5 http://${module.vpc_b.public_dns}/"]' \
      --query Command.CommandId --output text)
    aws ssm wait command-executed ${local.aws_flags} --command-id "$CMD" --instance-id ${module.vpc_a.instance_id} || true
    aws ssm get-command-invocation ${local.aws_flags} --command-id "$CMD" --instance-id ${module.vpc_a.instance_id} \
      --query StandardOutputContent --output text
  EOT
}

output "test_b_to_a_command" {
  description = "From the VPC-B instance: ping and HTTP to the VPC-A instance by private IP, then by public DNS name (resolves to the private IP)"
  value       = <<-EOT
    CMD=$(aws ssm send-command ${local.aws_flags} --instance-ids ${module.vpc_b.instance_id} \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["ping -c 3 ${module.vpc_a.private_ip}","curl -s -m 5 http://${module.vpc_a.private_ip}/","getent hosts ${module.vpc_a.public_dns}","curl -s -m 5 http://${module.vpc_a.public_dns}/"]' \
      --query Command.CommandId --output text)
    aws ssm wait command-executed ${local.aws_flags} --command-id "$CMD" --instance-id ${module.vpc_b.instance_id} || true
    aws ssm get-command-invocation ${local.aws_flags} --command-id "$CMD" --instance-id ${module.vpc_b.instance_id} \
      --query StandardOutputContent --output text
  EOT
}
