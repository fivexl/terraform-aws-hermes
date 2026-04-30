data "aws_region" "current" {}

################################################################################
# VPC and Subnet Discovery
################################################################################

data "aws_vpc" "default" {
  count   = var.subnet_id == null ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = var.subnet_id == null ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnet" "selected" {
  id = coalesce(var.subnet_id, sort(data.aws_subnets.default[0].ids)[0])
}

################################################################################
# AMI
################################################################################

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

################################################################################
# Cloud-Init
################################################################################

data "cloudinit_config" "this" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    filename     = "bootstrap.sh"
    content = templatefile("${path.module}/templates/user_data.sh.tpl", {
      region                 = data.aws_region.current.id
      az                     = local.az
      data_path              = var.data_path
      compose_dir            = local.compose_dir
      hermes_image           = local.hermes_image
      hermes_config          = local.hermes_config
      hermes_compose         = local.hermes_compose
      hermes_start_script    = local.hermes_start_script
      hermes_service         = local.hermes_service
      hermes_diagnose_script = local.hermes_diagnose_script
      volume_tag_name        = var.name
    })
  }
}
