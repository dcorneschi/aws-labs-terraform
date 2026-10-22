output "vpc_id" {
  value = aws_vpc.this.id
}

output "route_table_id" {
  value = aws_route_table.this.id
}

output "instance_id" {
  value = aws_instance.this.id
}

output "private_ip" {
  value = aws_instance.this.private_ip
}

output "private_dns" {
  value = aws_instance.this.private_dns
}

output "public_dns" {
  value = aws_instance.this.public_dns
}
