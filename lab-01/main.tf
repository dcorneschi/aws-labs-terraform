# ---------------------------------------------------------------------------
# Network and AMI: the default VPC and the latest Amazon Linux 2023 image
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
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
# Spot service-linked role (only if the account has never used Spot)
# ---------------------------------------------------------------------------
resource "aws_iam_service_linked_role" "spot" {
  count            = var.create_spot_service_linked_role ? 1 : 0
  aws_service_name = "spot.amazonaws.com"
}

# ---------------------------------------------------------------------------
# Security group: no inbound rules, all outbound (the instances only call out)
# ---------------------------------------------------------------------------
resource "aws_security_group" "this" {
  name        = "${var.name}-sg"
  description = "ASG lab: no inbound rules"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outbound"
}

# ---------------------------------------------------------------------------
# Role so Systems Manager can reach the instances (no SSH, no key pair)
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
  name               = "${var.name}-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-profile"
  role = aws_iam_role.this.name
}

# ---------------------------------------------------------------------------
# Launch template: what each instance looks like
# ---------------------------------------------------------------------------
locals {
  # True only when every instance type is a burstable T type (t2, t3, t3a, t4g, t8i ...)
  all_burstable = alltrue([for t in var.instance_types : can(regex("^t[0-9]", t))])
}

resource "aws_launch_template" "this" {
  name          = "${var.name}-lt"
  description   = "ASG lab launch template"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_types[0] # the ASG overrides replace this

  iam_instance_profile {
    name = aws_iam_instance_profile.this.name
  }

  vpc_security_group_ids = [aws_security_group.this.id]
  user_data              = base64encode(templatefile("${path.module}/user-data.sh.tftpl", { burn_script = file("${path.module}/burn.sh") }))

  # Detailed monitoring: CPU every minute, so the alarm reacts quickly (small extra cost)
  monitoring {
    enabled = true
  }

  # Only for T types: standard credits, so there are no surplus-credit charges. The setting is
  # not valid for other families, so it is left out for the default (non-burstable) types.
  dynamic "credit_specification" {
    for_each = local.all_burstable ? [1] : []
    content {
      cpu_credits = "standard"
    }
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = var.name
    }
  }

  # No instance_market_options here: with a mixed instances policy the ASG decides
  # between Spot and On-Demand.
}

# ---------------------------------------------------------------------------
# Auto Scaling group: all Spot, several instance types, default VPC subnets
# ---------------------------------------------------------------------------
resource "aws_autoscaling_group" "this" {
  name                      = var.name
  min_size                  = var.min_size
  max_size                  = var.max_size
  desired_capacity          = var.desired_capacity
  vpc_zone_identifier       = data.aws_subnets.default.ids
  health_check_type         = "EC2"
  health_check_grace_period = 120
  capacity_rebalance        = var.capacity_rebalance

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0 # no guaranteed On-Demand instance
      on_demand_percentage_above_base_capacity = 0 # 0 = everything above the base is Spot (the default is 100!)
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.this.id
        version            = "$Latest"
      }

      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  tag {
    key                 = "Name"
    value               = var.name
    propagate_at_launch = true
  }

  # The scaling policy changes the desired capacity, so do not undo it on the next apply
  lifecycle {
    ignore_changes = [desired_capacity]
  }

  depends_on = [aws_iam_service_linked_role.spot]
}

# ---------------------------------------------------------------------------
# Scale out: +1 instance when the group's average CPU is at or above the threshold
# ---------------------------------------------------------------------------
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "${var.name}-scale-out"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 300
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.name}-cpu-high"
  alarm_description   = "Average CPU of the ${var.name} group is at or above ${var.cpu_high_threshold} percent"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.cpu_high_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.this.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_out.arn]
}

# ---------------------------------------------------------------------------
# Optional scale in: -1 instance when CPU stays low for 5 minutes
# ---------------------------------------------------------------------------
resource "aws_autoscaling_policy" "scale_in" {
  count                  = var.enable_scale_in ? 1 : 0
  name                   = "${var.name}-scale-in"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 300
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  count               = var.enable_scale_in ? 1 : 0
  alarm_name          = "${var.name}-cpu-low"
  alarm_description   = "Average CPU of the ${var.name} group is at or below ${var.cpu_low_threshold} percent"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = var.cpu_low_threshold
  comparison_operator = "LessThanOrEqualToThreshold"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.this.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_in[0].arn]
}

# ---------------------------------------------------------------------------
# The instances the group has launched, for the outputs. The group launches them
# a little after "apply" finishes, so this list can be empty at first: run
# "terraform apply -refresh-only" after a minute (and again after a scale-out) to update it.
# The Name tag is set by this code on every instance (launch template and group).
# ---------------------------------------------------------------------------
data "aws_instances" "group" {
  filter {
    name   = "tag:Name"
    values = [var.name]
  }
  filter {
    name   = "instance-state-name"
    values = ["pending", "running"]
  }

  depends_on = [aws_autoscaling_group.this]
}

locals {
  first_instance_id = try(data.aws_instances.group.ids[0], "<instance-id>")
}

locals {
  # Added to every aws command in the outputs, so they run against the same Region and profile as Terraform
  aws_flags = "--region ${var.region}${var.profile == null ? "" : " --profile ${var.profile}"}"
}
