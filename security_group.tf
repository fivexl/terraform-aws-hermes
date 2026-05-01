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

  # Email egress is managed below with for_each (stable keys imap/smtp) so toggling email
  # does not renumber the module's internal count-based rules for HTTPS/DNS.
  egress_with_cidr_blocks = [
    {
      rule        = "https-443-tcp"
      cidr_blocks = "0.0.0.0/0"
      description = "HTTPS outbound"
    },
    {
      rule        = "dns-udp"
      cidr_blocks = "0.0.0.0/0"
      description = "DNS UDP outbound"
    },
    {
      rule        = "dns-tcp"
      cidr_blocks = "0.0.0.0/0"
      description = "DNS TCP outbound"
    },
  ]
}

resource "aws_vpc_security_group_egress_rule" "email" {
  for_each = local.email_egress_rules

  security_group_id = module.sg.security_group_id
  description       = each.value.description
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value.from_port
  to_port           = each.value.to_port
}
