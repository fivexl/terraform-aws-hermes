module "sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${var.name}-instance"
  description = "Hermes instance - no ingress, restricted egress"
  vpc_id      = local.vpc_id
  tags        = local.common_tags

  use_name_prefix = false

  ingress_rules = []

  # Previous implementation was IPv4-only (no ::/0 rules).
  egress_ipv6_cidr_blocks = []

  # Egress rules are attached separately (aws_vpc_security_group_egress_rule) with for_each and
  # stable keys (https, dns_udp, dns_tcp, imap, smtp) instead of the module's count-based rules.
  egress_with_cidr_blocks = []
}

resource "aws_vpc_security_group_egress_rule" "egress" {
  for_each = local.sg_egress_rules

  security_group_id = module.sg.security_group_id
  description       = each.value.description
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
}
