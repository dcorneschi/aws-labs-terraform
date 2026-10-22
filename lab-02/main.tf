# ---------------------------------------------------------------------------
# Two VPCs in the same account and Region, each with one test instance
# ---------------------------------------------------------------------------
module "vpc_a" {
  source = "./modules/vpc-with-instance"

  name          = "${var.name}-vpc-a"
  label         = "VPC-A"
  cidr          = var.vpc_a_cidr
  peer_cidr     = var.vpc_b_cidr
  instance_type = var.instance_type
}

module "vpc_b" {
  source = "./modules/vpc-with-instance"

  name          = "${var.name}-vpc-b"
  label         = "VPC-B"
  cidr          = var.vpc_b_cidr
  peer_cidr     = var.vpc_a_cidr
  instance_type = var.instance_type
}

# ---------------------------------------------------------------------------
# Peering connection: VPC-A requests, VPC-B accepts. Same account and Region,
# so auto_accept makes it active right away.
# ---------------------------------------------------------------------------
resource "aws_vpc_peering_connection" "a_to_b" {
  vpc_id      = module.vpc_a.vpc_id
  peer_vpc_id = module.vpc_b.vpc_id
  auto_accept = true

  tags = {
    Name = "${var.name}-a-to-b"
  }
}

# Public DNS names of the other VPC's instances (ec2-x-x-x-x.<region>.compute.amazonaws.com)
# resolve to their private IPs, so traffic to them stays on the peering. Without it they
# resolve to the public IP, which the security groups do not allow.
resource "aws_vpc_peering_connection_options" "a_to_b" {
  vpc_peering_connection_id = aws_vpc_peering_connection.a_to_b.id

  requester {
    allow_remote_vpc_dns_resolution = true
  }

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

# ---------------------------------------------------------------------------
# Routes: peering does nothing until each side routes the other CIDR to it
# ---------------------------------------------------------------------------
resource "aws_route" "a_to_b" {
  route_table_id            = module.vpc_a.route_table_id
  destination_cidr_block    = var.vpc_b_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.a_to_b.id
}

resource "aws_route" "b_to_a" {
  route_table_id            = module.vpc_b.route_table_id
  destination_cidr_block    = var.vpc_a_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.a_to_b.id
}

locals {
  # Added to every aws command in the outputs, so they run against the same Region and profile as Terraform
  aws_flags = "--region ${var.region}${var.profile == null ? "" : " --profile ${var.profile}"}"
}
