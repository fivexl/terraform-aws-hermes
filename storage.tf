resource "aws_ebs_volume" "data" {
  availability_zone = local.az
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = merge(local.common_tags, {
    Name             = "${var.name}-data"
    HermesVolumeRole = "data"
  })

  lifecycle {
    prevent_destroy = true
  }
}
