################################################################################
# General
################################################################################

variable "name" {
  description = "Deployment name. Used in resource names, tags, and volume discovery."
  type        = string
  default     = "hermes"
}

variable "tags" {
  description = "Additional tags to apply to all resources."
  type        = map(string)
  default     = {}
}

################################################################################
# Compute
################################################################################

variable "instance_type" {
  description = "EC2 instance type. Must be arm64-compatible."
  type        = string
  default     = "t4g.medium"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 16

  validation {
    condition     = var.root_volume_size >= 8
    error_message = "Root volume size must be at least 8 GiB."
  }
}

################################################################################
# Network
################################################################################

variable "subnet_id" {
  description = "Subnet ID override. If null, auto-discovers default VPC and deterministically selects a default subnet."
  type        = string
  default     = null
}

################################################################################
# Storage
################################################################################

variable "data_volume_size" {
  description = "Persistent data EBS volume size in GiB."
  type        = number
  default     = 20

  validation {
    condition     = var.data_volume_size >= 10
    error_message = "Data volume size must be at least 10 GiB."
  }
}

variable "data_path" {
  description = "Mount path for the persistent data volume on the EC2 instance."
  type        = string
  default     = "/var/lib/hermes"
}

################################################################################
# Hermes
################################################################################

variable "hermes_version" {
  description = <<-EOT
    Exact Hermes Docker image tag for nousresearch/hermes-agent (must exist on Docker Hub).
    Upstream publishes dated tags such as v2026.4.30 — see:
    https://hub.docker.com/r/nousresearch/hermes-agent/tags
    Do not use the "latest" tag here.
  EOT
  type        = string

  validation {
    condition     = length(var.hermes_version) > 0 && var.hermes_version != "latest"
    error_message = "hermes_version must be a non-empty tag and cannot be \"latest\"."
  }
}

################################################################################
# Bedrock
################################################################################

variable "bedrock_region" {
  description = "AWS region for Bedrock API calls."
  type        = string
  default     = "us-east-1"
}

variable "bedrock_model_id" {
  description = "Default Bedrock model ID for Hermes inference."
  type        = string
  default     = "nvidia.nemotron-super-3-120b"
}

variable "bedrock_discovery_enabled" {
  description = "Enable Hermes Bedrock model discovery (auto-detect available models at runtime). Adds ListFoundationModels and ListInferenceProfiles IAM permissions."
  type        = bool
  default     = true
}

################################################################################
# Slack
################################################################################

variable "slack_enabled" {
  description = "Enable Slack Socket Mode (SSM parameters + gateway env). Set false for email-only deployments."
  type        = bool
  default     = true

  validation {
    condition     = var.slack_enabled || var.email_enabled
    error_message = "At least one messaging channel must be enabled: set slack_enabled or email_enabled to true."
  }
}

variable "slack_home_channel" {
  description = "Slack channel ID for cron job delivery (SLACK_HOME_CHANNEL). Empty string disables home channel."
  type        = string
  default     = ""
}

variable "slack_allowed_users" {
  description = "Slack user IDs allowed to use Hermes (SLACK_ALLOWED_USERS). Empty list keeps module behavior \"open workspace\": sets GATEWAY_ALLOW_ALL_USERS=true so the Hermes gateway does not deny everyone by default."
  type        = list(string)
  default     = []
}

################################################################################
# Email (IMAP/SMTP)
################################################################################

variable "email_enabled" {
  description = "Enable Hermes email adapter (IMAP/SMTP). Requires non-empty email_address, email_imap_host, and email_smtp_host when true."
  type        = bool
  default     = false
}

variable "email_address" {
  description = "Dedicated mailbox address for the agent (EMAIL_ADDRESS)."
  type        = string
  default     = ""

  validation {
    condition     = !var.email_enabled || length(trimspace(var.email_address)) > 0
    error_message = "When email_enabled is true, email_address must be non-empty."
  }
}

variable "email_imap_host" {
  description = "IMAP server hostname (EMAIL_IMAP_HOST), e.g. imap.gmail.com."
  type        = string
  default     = ""

  validation {
    condition     = !var.email_enabled || length(trimspace(var.email_imap_host)) > 0
    error_message = "When email_enabled is true, email_imap_host must be non-empty."
  }
}

variable "email_smtp_host" {
  description = "SMTP server hostname (EMAIL_SMTP_HOST), e.g. smtp.gmail.com."
  type        = string
  default     = ""

  validation {
    condition     = !var.email_enabled || length(trimspace(var.email_smtp_host)) > 0
    error_message = "When email_enabled is true, email_smtp_host must be non-empty."
  }
}

variable "email_imap_port" {
  description = "IMAP port (EMAIL_IMAP_PORT). Default 993 (SSL)."
  type        = number
  default     = 993

  validation {
    condition     = var.email_imap_port >= 1 && var.email_imap_port <= 65535
    error_message = "email_imap_port must be between 1 and 65535."
  }
}

variable "email_smtp_port" {
  description = "SMTP port (EMAIL_SMTP_PORT). Default 587 (STARTTLS)."
  type        = number
  default     = 587

  validation {
    condition     = var.email_smtp_port >= 1 && var.email_smtp_port <= 65535
    error_message = "email_smtp_port must be between 1 and 65535."
  }
}

variable "email_poll_interval" {
  description = "Seconds between inbox polls (EMAIL_POLL_INTERVAL)."
  type        = number
  default     = 15

  validation {
    condition     = !var.email_enabled || var.email_poll_interval >= 1
    error_message = "When email_enabled is true, email_poll_interval must be at least 1."
  }
}

variable "email_allowed_users" {
  description = "Sender addresses allowed to interact with the agent (EMAIL_ALLOWED_USERS). Empty list leaves Hermes default behavior (pairing); does not set EMAIL_ALLOW_ALL_USERS."
  type        = list(string)
  default     = []
}

variable "email_home_address" {
  description = "Default delivery address for cron-style jobs (EMAIL_HOME_ADDRESS). Optional."
  type        = string
  default     = ""
}

variable "email_allow_all_users" {
  description = <<-EOT
    When true, sets EMAIL_ALLOW_ALL_USERS=true so any sender can use the agent.
    WARNING: This opens a serious abuse vector — anyone who learns the mailbox address can interact with an agent that often has powerful tools enabled.
    Prefer email_allowed_users. Only enable with deliberate risk acceptance.
  EOT
  type        = bool
  default     = false
}

variable "email_skip_attachments" {
  description = "When email_enabled, sets platforms.email.skip_attachments in config.yaml (skip inbound attachments before decoding)."
  type        = bool
  default     = false
}

################################################################################
# API Server
################################################################################

variable "api_server_enabled" {
  description = "Enable the OpenAI-compatible API server on port 8642. When enabled, an API_SERVER_KEY is auto-generated and stored in SSM."
  type        = bool
  default     = false
}

################################################################################
# SSM / Secrets
################################################################################

variable "ssm_parameter_prefix" {
  description = "SSM Parameter Store path prefix for all Hermes secrets."
  type        = string
  default     = "/hermes"

  validation {
    condition     = length(var.ssm_parameter_prefix) >= 2 && startswith(var.ssm_parameter_prefix, "/")
    error_message = "ssm_parameter_prefix must be a non-empty hierarchical path starting with / (e.g. /hermes)."
  }
}

################################################################################
# Logging
################################################################################

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days."
  type        = number
  default     = 30

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a valid CloudWatch Logs retention value."
  }
}

################################################################################
# Schedule
################################################################################

variable "instance_refresh_cron" {
  description = "EventBridge Scheduler cron expression for weekly ASG instance refresh (default: Sunday 01:00 UTC)."
  type        = string
  default     = "0 1 ? * SUN *"
}
