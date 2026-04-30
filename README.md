# terraform-aws-hermes

Terraform module to deploy [Hermes](https://github.com/nousresearch/hermes-agent) on AWS EC2 using immutable infrastructure principles.

Hermes is an open-source, self-improving AI agent by NousResearch that supports 30+ LLM providers and multiple messaging platforms. This module deploys it as a single-node Docker Compose service backed by Amazon Bedrock for inference and Slack Socket Mode for messaging.

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
- Slack App with Socket Mode enabled ([setup guide](docs/runbook.md#2-create-slack-app))
- After `terraform apply`, set real values on the module-created SSM parameters:
  - Slack tokens: `<prefix>/slack/bot_token` and `<prefix>/slack/app_token` ([instructions](docs/runbook.md#4-set-slack-token-values))
  - Agent personality: `<prefix>/soul_md` ([instructions](docs/runbook.md#5-set-soul_md))
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
