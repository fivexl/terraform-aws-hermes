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
