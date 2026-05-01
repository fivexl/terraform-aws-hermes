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

  egress_with_cidr_blocks = concat(
    [
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
    ],
    var.email_enabled ? [
      {
        from_port   = var.email_imap_port
        to_port     = var.email_imap_port
        protocol    = "tcp"
        description = "IMAP (Hermes email)"
        cidr_blocks = "0.0.0.0/0"
      },
      {
        from_port   = var.email_smtp_port
        to_port     = var.email_smtp_port
        protocol    = "tcp"
        description = "SMTP (Hermes email)"
        cidr_blocks = "0.0.0.0/0"
      },
    ] : [],
  )
}
