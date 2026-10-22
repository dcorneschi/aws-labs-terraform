# ---------------------------------------------------------------------------
# VPC with one public subnet. The subnet only gives the instance a way out to
# Systems Manager; nothing on the internet can reach it (no inbound rule allows it).
# ---------------------------------------------------------------------------
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # needed for DNS resolution across the peering

  tags = {
    Name = var.name
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = var.name
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.cidr, 8, 1) # 10.x.1.0/24 for a /16
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true # outbound to Systems Manager without a NAT gateway

  tags = {
    Name = "${var.name}-public"
  }
}

# The route to the other VPC is added by the root module, because it needs the
# peering connection ID.
resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = var.name
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.this.id
}

# ---------------------------------------------------------------------------
# Security group: ping and HTTP from the other VPC only, all outbound
# ---------------------------------------------------------------------------
resource "aws_security_group" "this" {
  name        = "${var.name}-sg"
  description = "Peering lab: ICMP and HTTP from the peer VPC only"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "icmp_from_peer" {
  security_group_id = aws_security_group.this.id
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  cidr_ipv4         = var.peer_cidr
  description       = "Ping from the peer VPC"
}

resource "aws_vpc_security_group_ingress_rule" "http_from_peer" {
  security_group_id = aws_security_group.this.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = var.peer_cidr
  description       = "HTTP from the peer VPC"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outbound"
}

# ---------------------------------------------------------------------------
# Role so Systems Manager can reach the instance (no SSH, no key pair)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-ssm"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-ssm"
  role = aws_iam_role.this.name
}

# ---------------------------------------------------------------------------
# Test instance: Amazon Linux 2023 with a tiny web page that names its VPC
# ---------------------------------------------------------------------------
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "this" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name
  user_data              = templatefile("${path.module}/user-data.sh.tftpl", { label = var.label })

  # Standard credits for T types, so there are no surplus-credit charges
  dynamic "credit_specification" {
    for_each = can(regex("^t[0-9]", var.instance_type)) ? [1] : []
    content {
      cpu_credits = "standard"
    }
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  tags = {
    Name = var.name
  }

  # A newer AMI must not replace a running test instance
  lifecycle {
    ignore_changes = [ami]
  }
}
