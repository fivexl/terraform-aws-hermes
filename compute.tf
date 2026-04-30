################################################################################
# Launch Template
################################################################################

resource "aws_launch_template" "this" {
  name          = "${var.name}-launch-template"
  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type

  user_data = data.cloudinit_config.this.rendered

  iam_instance_profile {
    arn = module.instance_role.instance_profile_arn
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [module.sg.security_group_id]
    delete_on_termination       = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = local.common_tags
  }

  tag_specifications {
    resource_type = "volume"

    tags = local.common_tags
  }

  update_default_version = true
  tags                   = local.common_tags
}

################################################################################
# Auto Scaling Group
################################################################################

resource "aws_autoscaling_group" "this" {
  name                = "${var.name}-asg"
  desired_capacity    = 1
  min_size            = 1
  max_size            = 1
  vpc_zone_identifier = [local.subnet_id]

  health_check_type         = "EC2"
  health_check_grace_period = 300
  wait_for_capacity_timeout = "10m"

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 0
    }
  }

  dynamic "tag" {
    for_each = local.common_tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

################################################################################
# Weekly Instance Refresh (EventBridge Scheduler)
################################################################################

data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "scheduler_asg" {
  statement {
    actions   = ["autoscaling:StartInstanceRefresh"]
    resources = [aws_autoscaling_group.this.arn]
  }
}

resource "aws_iam_policy" "scheduler_asg" {
  name   = "${var.name}-scheduler-asg"
  policy = data.aws_iam_policy_document.scheduler_asg.json
  tags   = local.common_tags
}

module "scheduler_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name            = "${var.name}-scheduler"
  use_name_prefix = false
  tags            = local.common_tags

  source_trust_policy_documents = [data.aws_iam_policy_document.scheduler_trust.json]

  create_instance_profile = false

  policies = {
    asg_refresh = aws_iam_policy.scheduler_asg.arn
  }
}

resource "aws_scheduler_schedule" "weekly_refresh" {
  name                = "${var.name}-weekly-instance-refresh"
  schedule_expression = "cron(${var.instance_refresh_cron})"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:autoscaling:startInstanceRefresh"
    role_arn = module.scheduler_role.arn

    input = jsonencode({
      AutoScalingGroupName = aws_autoscaling_group.this.name
      Strategy             = "Rolling"
      Preferences = {
        MinHealthyPercentage = 0
      }
    })
  }
}
