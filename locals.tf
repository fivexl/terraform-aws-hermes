locals {
  region    = data.aws_region.current.id
  az        = data.aws_subnet.selected.availability_zone
  vpc_id    = data.aws_subnet.selected.vpc_id
  subnet_id = data.aws_subnet.selected.id

  common_tags = merge(var.tags, {
    Name             = var.name
    Project          = "hermes"
    HermesDeployment = var.name
  })

  # All egress is aws_vpc_security_group_egress_rule with stable for_each keys (see security_group.tf).
  sg_email_egress_rules = var.email_enabled ? {
    imap = {
      ip_protocol = "tcp"
      from_port   = var.email_imap_port
      to_port     = var.email_imap_port
      description = "IMAP (Hermes email)"
    }
    smtp = {
      ip_protocol = "tcp"
      from_port   = var.email_smtp_port
      to_port     = var.email_smtp_port
      description = "SMTP (Hermes email)"
    }
  } : {}

  sg_egress_rules = merge(
    {
      https = {
        ip_protocol = "tcp"
        from_port   = 443
        to_port     = 443
        description = "HTTPS outbound"
      }
      dns_udp = {
        ip_protocol = "udp"
        from_port   = 53
        to_port     = 53
        description = "DNS UDP outbound"
      }
      dns_tcp = {
        ip_protocol = "tcp"
        from_port   = 53
        to_port     = 53
        description = "DNS TCP outbound"
      }
    },
    local.sg_email_egress_rules,
  )

  # SSM parameter paths
  ssm_slack_bot_token_path = "${var.ssm_parameter_prefix}/slack/bot_token"
  ssm_slack_app_token_path = "${var.ssm_parameter_prefix}/slack/app_token"
  ssm_email_password_path  = "${var.ssm_parameter_prefix}/email/password"
  ssm_soul_md_path         = "${var.ssm_parameter_prefix}/soul_md"
  ssm_api_server_key_path  = "${var.ssm_parameter_prefix}/api_server_key"

  ssm_parameter_arns = concat(
    var.slack_enabled ? [
      aws_ssm_parameter.slack_bot_token[0].arn,
      aws_ssm_parameter.slack_app_token[0].arn,
    ] : [],
    [
      aws_ssm_parameter.soul_md.arn,
    ],
    var.api_server_enabled ? [aws_ssm_parameter.api_server_key[0].arn] : [],
    var.email_enabled ? [aws_ssm_parameter.email_password[0].arn] : [],
  )

  # CloudWatch
  log_group_name = "/hermes/${var.name}"

  # Bedrock model ARN for IAM: foundation models use the account-less ARN; regional inference
  # profile IDs (e.g. us.anthropic.*) require ...:inference-profile/<id> in the caller's account.
  bedrock_model_arn = (
    can(regex("^[a-z]{2}\\.", var.bedrock_model_id))
    ? "arn:aws:bedrock:${var.bedrock_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_id}"
    : "arn:aws:bedrock:${var.bedrock_region}::foundation-model/${var.bedrock_model_id}"
  )

  # Container image reference
  hermes_image = "nousresearch/hermes-agent:${var.hermes_version}"

  # Slack allowed users joined for env var
  slack_allowed_users_csv = join(",", var.slack_allowed_users)

  # Hermes gateway denies all users unless allowlists are set; match module doc when list is empty.
  slack_gateway_allow_all_users = length(var.slack_allowed_users) == 0

  # Host-side path for Docker Compose configuration
  compose_dir = "/opt/hermes"

  # Rendered sub-templates
  hermes_config = templatefile("${path.module}/templates/hermes_config.yaml.tpl", {
    bedrock_region            = var.bedrock_region
    bedrock_model_id          = var.bedrock_model_id
    bedrock_discovery_enabled = var.bedrock_discovery_enabled
    email_enabled             = var.email_enabled
    email_skip_attachments    = var.email_skip_attachments
  })

  hermes_compose = templatefile("${path.module}/templates/docker-compose.yml.tpl", {
    image                   = local.hermes_image
    data_path               = var.data_path
    log_group_name          = local.log_group_name
    region                  = local.region
    api_server_enabled      = var.api_server_enabled
    slack_enabled           = var.slack_enabled
    email_enabled           = var.email_enabled
    email_address           = var.email_address
    email_imap_host         = var.email_imap_host
    email_smtp_host         = var.email_smtp_host
    email_imap_port         = var.email_imap_port
    email_smtp_port         = var.email_smtp_port
    email_poll_interval     = var.email_poll_interval
    email_allowed_users_csv = join(",", var.email_allowed_users)
    email_allowed_users_set = length(var.email_allowed_users) > 0
    email_home_address      = var.email_home_address
    email_home_address_set  = length(trimspace(var.email_home_address)) > 0
    email_allow_all_users   = var.email_allow_all_users
  })

  hermes_start_script = templatefile("${path.module}/templates/hermes-start.sh.tpl", {
    region                        = local.region
    slack_enabled                 = var.slack_enabled
    email_enabled                 = var.email_enabled
    ssm_slack_bot_token_path      = local.ssm_slack_bot_token_path
    ssm_slack_app_token_path      = local.ssm_slack_app_token_path
    ssm_email_password_path       = local.ssm_email_password_path
    ssm_soul_md_path              = local.ssm_soul_md_path
    ssm_api_server_key_path       = local.ssm_api_server_key_path
    data_path                     = var.data_path
    compose_dir                   = local.compose_dir
    slack_home_channel            = var.slack_home_channel
    slack_allowed_users           = local.slack_allowed_users_csv
    slack_gateway_allow_all_users = local.slack_gateway_allow_all_users
    api_server_enabled            = var.api_server_enabled
  })

  hermes_service = templatefile("${path.module}/templates/hermes.service.tpl", {
    compose_dir = local.compose_dir
    data_path   = var.data_path
  })

  hermes_diagnose_script = templatefile("${path.module}/templates/hermes-diagnose.sh.tpl", {
    region                   = local.region
    data_path                = var.data_path
    compose_dir              = local.compose_dir
    slack_enabled            = var.slack_enabled
    email_enabled            = var.email_enabled
    ssm_slack_bot_token_path = local.ssm_slack_bot_token_path
    ssm_slack_app_token_path = local.ssm_slack_app_token_path
    ssm_email_password_path  = local.ssm_email_password_path
    ssm_soul_md_path         = local.ssm_soul_md_path
    ssm_api_server_key_path  = local.ssm_api_server_key_path
    api_server_enabled       = var.api_server_enabled
  })
}
