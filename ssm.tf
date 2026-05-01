resource "aws_ssm_parameter" "slack_bot_token" {
  count = var.slack_enabled ? 1 : 0

  name        = local.ssm_slack_bot_token_path
  description = "Slack bot token (xoxb-...). Replace value manually after apply."
  type        = "SecureString"
  value       = "REPLACE_WITH_SLACK_BOT_TOKEN"
  tags        = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "slack_app_token" {
  count = var.slack_enabled ? 1 : 0

  name        = local.ssm_slack_app_token_path
  description = "Slack app token (xapp-...). Replace value manually after apply."
  type        = "SecureString"
  value       = "REPLACE_WITH_SLACK_APP_TOKEN"
  tags        = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "email_password" {
  count = var.email_enabled ? 1 : 0

  name        = local.ssm_email_password_path
  description = "Email app password for Hermes (EMAIL_PASSWORD). Replace value manually after apply."
  type        = "SecureString"
  value       = "REPLACE_WITH_EMAIL_PASSWORD"
  tags        = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "soul_md" {
  name        = local.ssm_soul_md_path
  description = "Hermes agent personality (SOUL.md). Replace value manually after apply."
  type        = "SecureString"
  value       = "REPLACE_WITH_SOUL_MD"
  tags        = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "random_password" "api_server_key" {
  count = var.api_server_enabled ? 1 : 0

  length  = 64
  special = false
}

resource "aws_ssm_parameter" "api_server_key" {
  count = var.api_server_enabled ? 1 : 0

  name        = local.ssm_api_server_key_path
  description = "Hermes API server bearer token (auto-generated)."
  type        = "SecureString"
  value       = random_password.api_server_key[0].result
  tags        = local.common_tags
}
