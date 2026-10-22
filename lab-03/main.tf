# ---------------------------------------------------------------------------
# Network: the default VPC of each Region
# ---------------------------------------------------------------------------
data "aws_vpc" "primary" {
  default = true
}

data "aws_subnets" "primary" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.primary.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_vpc" "secondary" {
  provider = aws.secondary
  default  = true
}

data "aws_subnets" "secondary" {
  provider = aws.secondary
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.secondary.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ---------------------------------------------------------------------------
# Security groups: no inbound rules, all outbound (one per Region)
# ---------------------------------------------------------------------------
resource "aws_security_group" "primary" {
  name        = "${var.name}-sg"
  description = "AMI lab: no inbound rules"
  vpc_id      = data.aws_vpc.primary.id
}

resource "aws_vpc_security_group_egress_rule" "primary_all" {
  security_group_id = aws_security_group.primary.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outbound"
}

resource "aws_security_group" "secondary" {
  provider    = aws.secondary
  name        = "${var.name}-sg"
  description = "AMI lab: no inbound rules"
  vpc_id      = data.aws_vpc.secondary.id
}

resource "aws_vpc_security_group_egress_rule" "secondary_all" {
  provider          = aws.secondary
  security_group_id = aws_security_group.secondary.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outbound"
}

# ---------------------------------------------------------------------------
# Role so Systems Manager can reach the instances. IAM is global, so the same
# instance profile works in both Regions.
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
# Source instance in the primary Region. User data writes a marker file that
# ends up in the AMI.
# ---------------------------------------------------------------------------
resource "aws_instance" "source" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = sort(data.aws_subnets.primary.ids)[0]
  vpc_security_group_ids = [aws_security_group.primary.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name
  user_data              = file("${path.module}/user-data.sh")

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
    Name = "${var.name}-source"
  }

  # A newer AMI must not replace the source instance
  lifecycle {
    ignore_changes = [ami]
  }
}

# ---------------------------------------------------------------------------
# Backup: an AMI of the source instance (an EBS snapshot of its root volume plus
# the launch settings). EC2 reboots the instance so the file system is consistent.
# ---------------------------------------------------------------------------
resource "time_sleep" "user_data" {
  # Give user data time to write the marker before the image is taken
  create_duration = "90s"
  depends_on      = [aws_instance.source]
}

resource "aws_ami_from_instance" "backup" {
  name                    = "${var.name}-backup"
  description             = "Backup of ${aws_instance.source.id} (${var.region})"
  source_instance_id      = aws_instance.source.id
  snapshot_without_reboot = false # reboot: consistent file system

  tags = {
    Name = "${var.name}-backup"
  }

  depends_on = [time_sleep.user_data]
}

# ---------------------------------------------------------------------------
# Disaster recovery copy in the secondary Region. Copying takes several minutes;
# Terraform waits until the copy is available.
# ---------------------------------------------------------------------------
resource "aws_ami_copy" "secondary" {
  provider          = aws.secondary
  name              = aws_ami_from_instance.backup.name
  description       = "Copy of ${aws_ami_from_instance.backup.id} from ${var.region}"
  source_ami_id     = aws_ami_from_instance.backup.id
  source_ami_region = var.region
  encrypted         = var.encrypt_copy # default key aws/ebs of the secondary Region

  tags = {
    Name      = "${var.name}-backup-copy"
    SourceAmi = aws_ami_from_instance.backup.id
  }

  lifecycle {
    precondition {
      condition     = var.secondary_region != var.region
      error_message = "secondary_region must be different from region."
    }
  }
}

# ---------------------------------------------------------------------------
# Restore: a new instance in the secondary Region from the copied AMI
# ---------------------------------------------------------------------------
resource "aws_instance" "restored" {
  count    = var.restore ? 1 : 0
  provider = aws.secondary

  ami                    = aws_ami_copy.secondary.id
  instance_type          = var.instance_type
  subnet_id              = sort(data.aws_subnets.secondary.ids)[0]
  vpc_security_group_ids = [aws_security_group.secondary.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name

  dynamic "credit_specification" {
    for_each = can(regex("^t[0-9]", var.instance_type)) ? [1] : []
    content {
      cpu_credits = "standard"
    }
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = {
    Name = "${var.name}-restored"
  }
}

locals {
  # Added to the aws commands in the outputs, so they run against the right Region and profile
  profile_flag    = var.profile == null ? "" : " --profile ${var.profile}"
  primary_flags   = "--region ${var.region}${local.profile_flag}"
  secondary_flags = "--region ${var.secondary_region}${local.profile_flag}"
  restored_id     = try(aws_instance.restored[0].id, "<restored-instance-id>")
  check_commands  = "commands=[\"cat /etc/ami-lab-marker\",\"/usr/local/bin/ami-lab-whereami\"]"
}
