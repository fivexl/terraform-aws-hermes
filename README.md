[![FivexL](https://releases.fivexl.io/like-this-repo-banner.png)](https://fivexl.io/#email-subscription)

### Want practical AWS infrastructure insights?

👉 [Subscribe to our newsletter](https://fivexl.io/#email-subscription) to get:

- Real stories from real AWS projects  
- No-nonsense DevOps tactics  
- Cost, security & compliance patterns that actually work  
- Expert guidance from engineers in the field

=========================================================================

# terraform-aws-hermes

Terraform module to deploy [Hermes](https://github.com/nousresearch/hermes-agent) on AWS EC2 using immutable infrastructure principles.

Hermes is an open-source, self-improving AI agent by NousResearch that supports 30+ LLM providers and multiple messaging platforms. This module deploys it as a single-node Docker Compose service backed by Amazon Bedrock for inference and **optional messaging channels that do not require exposing HTTP endpoints or public URLs**—typically **Slack Socket Mode** (WebSocket out) and/or **email** (IMAP/SMTP out). Enable each channel with Terraform flags (`slack_enabled`, `email_enabled`).

## Architecture

- **Single EC2 instance** (arm64, Amazon Linux 2023) managed by an Auto Scaling Group for automatic recovery
- **Docker Compose** runs the Hermes gateway and dashboard as containers with `network_mode: host`
- **Persistent EBS volume** preserves Hermes state across instance replacements
- **No SSH, no public ingress** -- administrative access through AWS Systems Manager Session Manager only
- **Dashboard** bound to `127.0.0.1:9119`, accessed via SSM port forwarding (no authentication -- localhost only)
- **Weekly instance refresh** rebuilds the instance on a schedule for immutable infrastructure hygiene
- **CloudWatch Logs** via Docker `awslogs` log driver

## Prerequisites

- AWS account with a default VPC (or provide a `subnet_id`)
- **At least one messaging channel** (`slack_enabled` and/or `email_enabled`; defaults keep Slack on and email off)
- If **`slack_enabled`** (default): Slack App with Socket Mode enabled ([runbook](docs/runbook.md#3-slack-app-when-slack_enabled--true))
- If **`email_enabled`**: dedicated mailbox, IMAP/SMTP reachability, app password stored in SSM ([runbook](docs/runbook.md#4-email-mailbox-when-email_enabled--true), [Hermes email docs](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/email))
- After `terraform apply`, set real values on SSM parameters the module creates (placeholders until you overwrite):
  - Slack (`slack_enabled`): `<prefix>/slack/bot_token`, `<prefix>/slack/app_token`
  - Email (`email_enabled`): `<prefix>/email/password`
  - Always: `<prefix>/soul_md`
  - Optional API: `<prefix>/api_server_key` when `api_server_enabled`
  See [Operator Runbook](docs/runbook.md) for exact steps.
- Bedrock model access enabled in your account for the configured model

## Usage

```hcl
module "hermes" {
  source  = "fivexl/hermes/aws"

  # Required: pin an existing tag from Docker Hub (dated tags, e.g. v2026.4.30).
  hermes_version = "v2026.4.30"

  # All other variables have sensible defaults.
  # See variables.tf for the full list.
}
```

### Access the Dashboard

```bash
# Find the instance ID
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$(terraform output -raw asg_name)" \
  --query "AutoScalingGroups[0].Instances[0].InstanceId" \
  --output text)

# Port forward
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["9119"],"localPortNumber":["9119"]}'

# Open http://localhost:9119 in your browser
```

## Documentation

- [Architecture & Design](docs/design.md) -- why the system is shaped this way
- [Operator Runbook](docs/runbook.md) -- day-to-day operations, troubleshooting, secret setup

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
