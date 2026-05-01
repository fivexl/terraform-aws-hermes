provider "aws" {
  region = "us-east-1"
}

module "hermes" {
  source = "../../"

  hermes_version = "v2026.4.30"

  # Bedrock defaults: us-east-1, us.anthropic.claude-haiku-4-5-20251001-v1:0
  # Network defaults: auto-discovers default VPC/subnet
  # Storage defaults: 20 GiB gp3 persistent volume at /var/lib/hermes

  tags = {
    Environment = "dev"
  }
}

output "asg_name" {
  value = module.hermes.asg_name
}

output "ssm_port_forward_command" {
  value = module.hermes.ssm_port_forward_command
}

output "slack_bot_token_ssm_parameter_name" {
  value = module.hermes.slack_bot_token_ssm_parameter_name
}
