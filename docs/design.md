# Architecture & Design

## What is Hermes?

Hermes is an open-source, self-improving AI agent by NousResearch. It provides a unified runtime for connecting AI models (30+ providers including AWS Bedrock, Anthropic, OpenAI, and others) to messaging channels (Slack, Discord, Telegram, and more). It runs as a self-hosted Docker container and manages agent workspaces, conversation state, memory, skills, and channel integrations.

## What is This Module?

This Terraform module deploys Hermes on a single AWS EC2 instance with:

- **Docker Compose** running the Hermes gateway and dashboard as containers
- **Amazon Bedrock** as the model backend (no API keys to manage, uses IAM)
- **Messaging without public ingress for adapters**: optional **Slack Socket Mode** (no Slack webhook URLs) and/or **email over IMAP/SMTP** (polling and outbound SMTP from the instance—see [`variables.tf`](../variables.tf) `slack_enabled`, `email_enabled`)
- **SSM Session Manager** as the only administrative access path
- **Persistent EBS volume** for Hermes state that survives instance replacement

## Why Single-Node + Persistent EBS + Immutable EC2?

### The Problem

Hermes maintains local state (agent workspaces, sessions, memories, skills). Running it requires persistent storage, but the instance should be disposable for security and operational hygiene.

### The Solution

1. **Immutable instances**: The EC2 instance is rebuilt from scratch on every replacement. Docker Compose configuration is rendered from Terraform inputs at boot time. No manual changes survive a rebuild -- this is intentional.

2. **Persistent EBS volume**: A separate gp3 EBS volume holds Hermes' data directory. This volume is created once by Terraform and reattached automatically during instance replacement. Data survives rebuilds.

3. **ASG for recovery**: The Auto Scaling Group (desired=1, min=1, max=1) provides automatic instance replacement if the instance becomes unhealthy. It is not used for horizontal scaling.

4. **Weekly refresh**: An EventBridge Scheduler triggers an ASG instance refresh weekly. This rebuilds the instance with the latest AMI and fresh configuration, preventing drift. With email enabled, upstream Hermes typically **marks existing mailbox messages as seen** on gateway startup and then continues polling—so scheduled replacements should not re-process historical mail as “new,” aside from ordinary boot downtime.

## Deployment Model

### Docker Compose

Hermes runs as two Docker containers managed by Docker Compose with `network_mode: host`:

| Container | Command | Purpose |
|-----------|---------|---------|
| `hermes-gateway` | `gateway run` | Messaging gateway (optional Slack / email per Terraform), Bedrock inference |
| `hermes-dashboard` | `dashboard --host 127.0.0.1 --no-open` | Web management UI (localhost-only) |

Both containers share the same persistent data volume mounted at `/opt/data` inside the container (host path: `/var/lib/hermes`). The Docker Compose file and related configuration live at `/opt/hermes/` on the host. The Docker `--restart unless-stopped` policy handles container failures.

### Container Image

The module uses the official `nousresearch/hermes-agent` Docker image, pinned to an exact tag via the required `hermes_version` variable (check Docker Hub for current tags; upstream publishes dated tags such as `v2026.4.30`). Prefer a tag **after** upstream Bedrock auxiliary fixes (e.g. PR `#15184`, ~2026-04-24) so context compression can use IAM-backed Bedrock instead of requiring `OPENROUTER_API_KEY`. The `latest` tag is never used by this module.

### Secret Injection

Hermes does not natively support AWS SSM Parameter Store. Secrets are injected through a systemd wrapper approach:

1. A systemd unit runs before Docker Compose starts
2. It fetches secrets from SSM Parameter Store using the AWS CLI
3. It exports them as environment variables in the shell process
4. It exec's `docker compose up` -- the containers inherit the environment
5. Secrets live only in process memory, never written to disk

This keeps live secret material out of:
- Terraform state (Slack tokens and email password use `lifecycle { ignore_changes = [value] }`)
- Files on any filesystem (root or persistent volume)
- Container images

Non-sensitive email settings (address, hosts, ports, allowlists, etc.) are rendered into `docker-compose.yml` from Terraform; only **`EMAIL_PASSWORD`** is fetched from SSM at startup.

### UID/GID Handling

The Hermes Docker image runs as a `hermes` user (default UID 10000). During bootstrap, the user data script queries the container for the actual UID/GID and chowns the data volume to match, ensuring the container can read/write its data directory regardless of upstream UID changes.

## Network Design

### Default VPC Strategy

The module uses the account's default VPC and a default subnet by default. This avoids the cost of a NAT Gateway while still providing internet egress through the default subnet's public IP assignment.

The instance receives a public IPv4 address, but this does not affect security: **there are zero ingress rules** on the security group. The public IP is needed only for outbound connectivity.

### Egress Restrictions

Outbound traffic is restricted to:

| Port | Protocol | Purpose |
|------|----------|---------|
| 443  | TCP      | HTTPS (AWS APIs, Slack WebSocket, Docker Hub) |
| 53   | UDP/TCP  | DNS resolution |
| `email_imap_port` (default 993) | TCP | IMAP when `email_enabled` |
| `email_smtp_port` (default 587) | TCP | SMTP when `email_enabled` |

Implementation uses **`aws_vpc_security_group_egress_rule`** with **`for_each`** and stable keys (`https`, `dns_udp`, `dns_tcp`, plus `imap` / `smtp` when email is enabled). The security-group module creates only the empty SG; it does not attach count-based egress rules for these ports.

### No SSH

There is no SSH key pair and no SSH ingress rule. All administrative access goes through AWS Systems Manager Session Manager, which provides:

- Audit logging via CloudTrail
- IAM-based access control
- No open ports required

## Bedrock Integration

The module uses Amazon Bedrock for model inference. This means:

- No API keys to manage -- the instance role has scoped `bedrock:InvokeModel` permissions
- Model access is controlled through IAM, not secret rotation
- The Bedrock region is configurable
- Model discovery is enabled by default (configurable), allowing Hermes to auto-detect available models at runtime
- A default model is configured for initial use (default: Anthropic Claude Haiku 4.5 inference profile `us.anthropic.claude-haiku-4-5-20251001-v1:0`). IAM uses an **inference-profile** ARN for IDs that match a regional prefix (`xx.`, e.g. `us.anthropic...`), and the standard **foundation-model** ARN otherwise.

## Messaging: Slack (`slack_enabled`)

When enabled (default), Slack uses Socket Mode exclusively:

- Persistent WebSocket to Slack—**no inbound HTTP** endpoint for Slack on your side
- Bot Token (xoxb-) and App Token (xapp-) in SSM; injected at container start
- `SLACK_HOME_CHANNEL`, `SLACK_ALLOWED_USERS`, and workspace-wide `GATEWAY_ALLOW_ALL_USERS` behavior follow Terraform variables (see `variables.tf`)

When `slack_enabled = false`, the module **does not** create Slack SSM parameters or pass Slack-related environment variables—useful for **email-only** deployments.

## Messaging: Email (`email_enabled`)

When enabled, Hermes uses provider **IMAP** and **SMTP** with credentials and tuning from Terraform plus **`EMAIL_PASSWORD`** from SSM (`<prefix>/email/password`). There is **no** listener or inbound URL for email—the instance polls outbound.

- When `email_enabled`, a `platforms.email` block is always written to `config.yaml` with `skip_attachments` set from the `email_skip_attachments` variable (`true` or `false`)
- Empty `email_allowed_users` does **not** set `EMAIL_ALLOW_ALL_USERS`; use `email_allow_all_users` only with deliberate risk acceptance

## Secret Management

### SSM Parameter Layout

| Path | Purpose | Created By |
|------|---------|-----------|
| `<prefix>/slack/bot_token` | Slack Bot Token | When `slack_enabled`; **value** set by operator |
| `<prefix>/slack/app_token` | Slack App Token | When `slack_enabled`; **value** set by operator |
| `<prefix>/email/password` | Email app password (`EMAIL_PASSWORD`) | When `email_enabled`; **value** set by operator |
| `<prefix>/soul_md` | Agent personality (SOUL.md) | Always; **value** set by operator |
| `<prefix>/api_server_key` | API server bearer token (when enabled) | Auto-generated |

### External Secret Ownership

The module creates SSM `SecureString` parameters for secrets used at boot (Slack tokens when enabled, email password when enabled, SOUL.md always) so paths and IAM stay aligned with Terraform.

Initial parameter values are placeholders where applicable; Terraform ignores changes to `value` after creation so operators set and rotate real values with the AWS CLI or console (`put-parameter --overwrite`) without Terraform fighting those updates. The API server key (when enabled) is generated by Terraform via `random_password`.

## Dashboard and API Server

### Dashboard (port 9119)

The Hermes dashboard provides a browser-based management UI with status, chat, config, sessions, logs, analytics, cron, and skills pages. It runs as a separate container alongside the gateway.

- Binds to `127.0.0.1` only (no public exposure)
- Has no built-in authentication
- Accessed via SSM port forwarding

### API Server (port 8642, optional)

An OpenAI-compatible HTTP API server can be enabled via the `api_server_enabled` variable (disabled by default). When enabled:

- Exposes `/v1/chat/completions`, `/v1/models`, and other OpenAI-compatible endpoints
- Protected by a bearer token (`API_SERVER_KEY`) auto-generated and stored in SSM
- Allows external tools (e.g., Open WebUI) to use Hermes as an LLM backend

## Persistent Volume Lifecycle

### Attachment Flow

On every boot, the user data script:

1. Discovers the volume by tags (`HermesDeployment=<name>`, `HermesVolumeRole=data`)
2. If the volume is still attached to a terminated instance, waits for clean detach (up to 5 minutes)
3. **Never force-detaches** -- fails startup rather than risking filesystem corruption
4. Attaches the volume and discovers the NVMe device via `/dev/disk/by-id/` symlinks
5. If the volume is blank (first boot), creates an XFS filesystem
6. If the volume has an existing XFS filesystem, mounts without reformatting
7. If the volume has an unexpected filesystem type, refuses to proceed

### Why Not Terraform Volume Attachment?

The ASG replaces instances with new instance IDs. Terraform's `aws_volume_attachment` would need to reference a specific instance ID, which changes on every replacement. Instead, the boot script handles attachment dynamically using tag-based discovery.

## Terraform Conventions

**Prefer `for_each` over `count`** when declaring several instances of the same resource type. Use a map with **stable, meaningful keys** (for example `https`, `dns_udp`, `imap`) so that adding, removing, or toggling one item does not reindex the rest and force unrelated replacements. This is the default approach in HashiCorp’s documentation for non-sequential resource sets.

Use **`count`** only when it is a better fit, for example a single optional resource (`count = var.enabled ? 1 : 0`) or when a **third-party module** only exposes list/`count` semantics and wrapping it would not improve address stability.

In this module, **security group egress** is implemented with `for_each` on `aws_vpc_security_group_egress_rule` (see [Egress restrictions](#egress-restrictions)); optional **Slack SSM parameters** use `count` because each is a single optional singleton.

## IAM Permissions

All permissions follow the principle of least privilege:

| Scope | Actions | Resource Constraint |
|-------|---------|-------------------|
| SSM Core | Session Manager | AWS managed policy |
| SSM Parameters | GetParameter | Exact parameter ARNs |
| Bedrock | InvokeModel, InvokeModelWithResponseStream | Specific model ARNs |
| Bedrock Discovery | ListFoundationModels, ListInferenceProfiles | All resources (when enabled) |
| EBS | DescribeVolumes, AttachVolume | Tag condition on AttachVolume |
| CloudWatch Logs | CreateLogGroup, CreateLogStream, PutLogEvents | Specific log group ARN |

## Logging

All container logs are shipped to CloudWatch via the Docker `awslogs` log driver. This eliminates the need for a CloudWatch agent on the instance.

| Log Stream | Content |
|-----------|---------|
| `hermes-gateway` | Gateway service logs |
| `hermes-dashboard` | Dashboard service logs |

Bootstrap and EBS attachment logs are captured via journald on the instance (`journalctl -t hermes-bootstrap` and `journalctl -t hermes-ebs`). These are not shipped to CloudWatch -- they are only available via SSM session or the EC2 system log in the AWS console. If the instance fails before SSM is available, check the EC2 system log.

## What is Intentionally Out of Scope in v1

- x86_64 support (arm64 only for cost efficiency)
- Custom VPC creation
- SSH access
- Multi-instance / HA deployment
- Messaging channels beyond **Slack and email** supported here (Discord, Telegram, etc. remain bring-your-own outside this module)
- Generic config override escape hatches
- Snapshot automation / backup scheduling
- Customer-managed KMS keys (uses AWS-managed EBS key)
- Force-detach behavior for volume recovery
