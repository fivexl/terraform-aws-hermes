################################################################################
# IAM Role and Instance Profile
################################################################################

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

################################################################################
# SSM Parameter Store (secret retrieval)
################################################################################

data "aws_iam_policy_document" "ssm_parameters" {
  statement {
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = local.ssm_parameter_arns
  }
}

resource "aws_iam_policy" "ssm_parameters" {
  name   = "${var.name}-ssm-params"
  policy = data.aws_iam_policy_document.ssm_parameters.json
  tags   = local.common_tags
}

################################################################################
# Bedrock Model Invocation
################################################################################

data "aws_iam_policy_document" "bedrock" {
  statement {
    sid = "InvokeConfiguredModel"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = [local.bedrock_model_arn]
  }

  dynamic "statement" {
    for_each = var.bedrock_discovery_enabled ? [1] : []

    content {
      sid = "DiscoverModels"
      actions = [
        "bedrock:ListFoundationModels",
        "bedrock:ListInferenceProfiles",
      ]
      resources = ["*"]
    }
  }
}

resource "aws_iam_policy" "bedrock" {
  name   = "${var.name}-bedrock"
  policy = data.aws_iam_policy_document.bedrock.json
  tags   = local.common_tags
}

################################################################################
# EBS Volume Discovery and Attachment
################################################################################

data "aws_iam_policy_document" "ebs" {
  statement {
    sid = "DescribeForDiscovery"
    actions = [
      "ec2:DescribeVolumes",
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "AttachVolume"
    actions   = ["ec2:AttachVolume"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/HermesDeployment"
      values   = [var.name]
    }
  }
}

resource "aws_iam_policy" "ebs" {
  name   = "${var.name}-ebs"
  policy = data.aws_iam_policy_document.ebs.json
  tags   = local.common_tags
}

################################################################################
# CloudWatch Logs (Docker awslogs driver)
################################################################################

data "aws_iam_policy_document" "cloudwatch_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      aws_cloudwatch_log_group.this.arn,
      "${aws_cloudwatch_log_group.this.arn}:log-stream:*",
    ]
  }
}

resource "aws_iam_policy" "cloudwatch_logs" {
  name   = "${var.name}-cw-logs"
  policy = data.aws_iam_policy_document.cloudwatch_logs.json
  tags   = local.common_tags
}

################################################################################
# EC2 instance role + profile (terraform-aws-modules)
################################################################################

module "instance_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name            = var.name
  use_name_prefix = false
  tags            = local.common_tags

  source_trust_policy_documents = [data.aws_iam_policy_document.trust.json]

  create_instance_profile = true

  policies = {
    ssm_core        = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    ssm_parameters  = aws_iam_policy.ssm_parameters.arn
    bedrock         = aws_iam_policy.bedrock.arn
    ebs             = aws_iam_policy.ebs.arn
    cloudwatch_logs = aws_iam_policy.cloudwatch_logs.arn
  }
}
