# Hermes AWS Module Design Brief

## Purpose

This module is intended to deploy Hermes on AWS EC2 using immutable-infrastructure principles. The EC2 instance is disposable. Persistent state lives on a separate EBS volume that survives instance replacement and is reattached automatically. Provisioning happens through templated user data. Access is through AWS Systems Manager Session Manager only. There is no SSH, no public admin surface, and no ingress rules.

The deployment target is the existing default VPC by default. The module should discover the default VPC and default subnets automatically via data sources, but allow the caller to override the subnet ID. If a subnet override is provided, the module should use it as-is without validating that it belongs to the default VPC.

Because the deployment relies on the default VPC/default subnet pattern to avoid NAT gateway cost, the EC2 instance is expected to receive a public IPv4 address when launched into the selected subnet. This does not change the security model: ingress remains fully disabled and administrative access remains SSM-only.

## Core Infrastructure Model

### VPC and Subnet Behavior

- By default, the module discovers the account's default VPC.
- By default, the module discovers default subnets and deterministically chooses one subnet/AZ when no subnet override is provided.
- The caller may override the subnet ID.
- If a subnet override is provided, the module must derive the EBS volume Availability Zone from that subnet's AZ.
- The module should not validate that an overridden subnet belongs to the default VPC.
- The Auto Scaling Group must be constrained to a single subnet in a single AZ because the persistent EBS volume can only attach within one AZ.

### Self-Contained Module

The module should create all required AWS resources for the deployment and be self-contained. That includes:

- EC2-related stack
- launch template
- Auto Scaling Group
- IAM role
- IAM instance profile
- security group
- CloudWatch log group
- persistent EBS volume
- SSM parameters for secrets and configuration
- Docker Compose configuration
- supporting resources needed to make the deployment work end to end

Where practical, the implementation should prefer open source Terraform modules from `terraform-aws-modules`.

## Compute and Operating System

### Platform Defaults

- Operating system: Amazon Linux 2023 standard AMI
- AMI source: latest AL2023 AMI resolved through AWS public SSM parameters
- Architecture: `arm64` only
- Default instance family: `t4g`
- Default instance type: `t4g.medium`

The system is expected to be cost-efficient, with model inference handled by Amazon Bedrock rather than on-box local models.

### Version Pinning

- Hermes version must always be pinned.
- The module must require an exact Hermes version input (Docker image tag) and provide no default.
- Bootstrap should install Docker and Docker Compose from Amazon Linux 2023 packages.
- Bootstrap must not run a broad `dnf upgrade`.
- Bootstrap should install only the exact required packages.
- The deployment should rely on the AWS CLI that is expected to be preinstalled on the standard AL2023 AMI and fail fast if it is missing.

## Deployment Runtime

### Docker Compose

Hermes runs as Docker containers managed by Docker Compose:

- Two containers: gateway and dashboard
- Both use `network_mode: host`
- Both mount the persistent EBS volume at `/opt/data` (container internal path)
- Docker restart policy: `unless-stopped`
- Image: `nousresearch/hermes-agent:<version>` with exact version tag (never `latest`)

### Container Configuration

- Docker Compose file and related host-side configuration live at `/opt/hermes/` on the host
- Hermes configuration via `config.yaml` rendered during bootstrap and placed on the data volume
- Secrets injected as environment variables through a systemd wrapper (never written to disk)
- Agent personality (`SOUL.md`) fetched from SSM and written to the data volume
- `HERMES_HOME` environment variable points to `/opt/data`

### UID/GID Handling

- The Hermes Docker image runs as a `hermes` user (default UID 10000, configurable upstream)
- During bootstrap, the user data script queries the container image for the actual UID/GID
- The data volume is chowned to match before starting Compose
- This ensures compatibility regardless of upstream UID changes

## Auto Scaling and Instance Lifecycle

### Auto Scaling Group Model

The deployment is single-node only. The Auto Scaling Group is used for automatic replacement and health recovery, not horizontal scaling.

- `desired_capacity = 1`
- `min_size = 1`
- `max_size = 1`

### Weekly Rotation

The module should enable weekly scheduled instance rotation using ASG instance refresh.

- mechanism: scheduled ASG instance refresh
- default schedule: Sunday at `01:00 UTC`
- health signal: EC2 health checks only in v1

### Provisioning Model

- All provisioning should happen in user data.
- SSM State Manager or SSM associations are out of scope.
- SSM is used only for Session Manager access and standard managed-instance behavior.

## Persistent Storage

### Data Volume

The persistent EBS volume is central to the design.

- volume type: `gp3`
- default size: `20 GiB`
- purpose: preserve Hermes data/state across EC2 replacement
- module should create the volume by default
- the volume must be preserved and reattached during instance replacement

Because the ASG replaces instances with changing instance IDs, Terraform should not manage a fixed `aws_volume_attachment` tied to a particular instance. Instead, the instance boot logic should discover, attach, and mount the tagged persistent volume at startup.

The module should own exactly one persistent data volume identified by tags.

### Safe Reattachment Behavior

For failure scenarios, the reattachment logic should prioritize data safety over aggressive failover.

- wait for clean volume detach from the old instance
- retry in a controlled manner
- do not force-detach by default
- fail startup rather than automatically stealing the disk aggressively

The instance role will therefore need tightly scoped EC2 permissions for EBS and instance discovery/attachment logic.

### Filesystem and Mounting

- filesystem: `xfs`
- default host mount path: `/var/lib/hermes`
- data path should remain an input with default `/var/lib/hermes`
- Docker containers mount this as `/opt/data` (Hermes' expected internal path)
- on first boot, if the volume is blank, bootstrap should initialize it with XFS and mount it
- if the volume already contains a filesystem or existing data, bootstrap must not reformat it
- if checks fail on a non-empty volume, bootstrap must refuse destructive reinitialization

### Root Volume

- root volume should be encrypted
- root volume default size: `16 GiB`
- both root and data volumes should use the AWS-managed EBS KMS key in v1

### Backup Scope

- snapshot automation and backup scheduling are out of scope for v1

## Network and Access Model

### Security Group

There should be no ingress rules at all.

Outbound egress should be restricted to:

- `443/tcp`
- `53/udp`
- `53/tcp`

### Administrative Access

- no SSH key pair
- Session Manager is the only administrative access path
- the instance should receive a public IPv4 address in the selected subnet because the design intentionally relies on default-VPC internet egress rather than NAT

### Dashboard Exposure

- Hermes dashboard binds to `127.0.0.1:9119` only
- operators access the dashboard through SSM port forwarding
- no public exposure is allowed
- the dashboard has no built-in authentication; localhost binding is the access control

### API Server (Optional)

- disabled by default, enabled via `api_server_enabled` variable
- when enabled, listens on port `8642` with bearer token authentication
- bearer token (`API_SERVER_KEY`) auto-generated by Terraform and stored in SSM
- exposes an OpenAI-compatible API for external tool integration

### IMDS Hardening

- IMDSv2 only
- hop limit: `1`

## IAM and Instance Profile

The module should create a dedicated IAM role and instance profile for this deployment only.

### Managed Policy

- attach `AmazonSSMManagedInstanceCore`

### Custom Least-Privilege Permissions

Custom permissions should be added only as needed, including:

- read access to the specific SSM parameter ARNs used by Hermes
- Bedrock invocation permissions for the configured model
- Bedrock discovery permissions (`ListFoundationModels`, `ListInferenceProfiles`) when discovery is enabled (default: enabled)
- EC2 permissions required for persistent volume discovery and attachment
- CloudWatch Logs permissions for the Docker `awslogs` log driver

EC2 permissions for volume attachment/discovery should be scoped as tightly as AWS realistically allows.

## Secrets and Configuration

### Secret Injection Model

Hermes does not natively support AWS SSM Parameter Store. Secrets are injected through a systemd wrapper:

1. A systemd unit runs before Docker Compose starts
2. It fetches all required SSM parameters using the AWS CLI
3. It exports them as environment variables in the shell process
4. It exec's `docker compose up` -- the containers inherit the environment
5. Secrets live only in process memory, never written to disk

This approach keeps live secret material out of:
- Terraform-managed configuration
- Files on any filesystem (root or persistent volume)
- Container images

### SOUL.md (Agent Personality)

- Stored as an SSM SecureString parameter at `<prefix>/soul_md`
- Fetched during bootstrap and written to the data volume as `/var/lib/hermes/SOUL.md`
- Terraform creates the parameter with a placeholder; operators set the real value
- `lifecycle { ignore_changes = [value] }` ensures Terraform does not overwrite operator content

### External Secret Ownership

The module creates SSM `SecureString` parameters for Slack tokens and SOUL.md so paths and IAM stay aligned with Terraform.

Initial parameter values are placeholders; Terraform ignores changes to `value` after creation so operators set and rotate real values with the AWS CLI or console (`put-parameter --overwrite`) without Terraform fighting those updates.

### SSM Parameter Prefix

- default SSM parameter prefix: `/hermes`
- prefix should remain an input with default `/hermes`
- default prefix should not derive from `name`

### SSM Parameters in v1

| Path | Purpose | Managed By |
|------|---------|-----------|
| `<prefix>/slack/bot_token` | Slack Bot Token | Operator |
| `<prefix>/slack/app_token` | Slack App Token | Operator |
| `<prefix>/soul_md` | Agent personality (SOUL.md) | Operator |
| `<prefix>/api_server_key` | API server bearer token (when enabled) | Terraform (auto-generated) |

## Hermes Runtime Configuration

### Config File

- Hermes configuration via `config.yaml` rendered during bootstrap
- Placed at `/var/lib/hermes/config.yaml`
- Rendered fresh on every boot from Terraform inputs
- Contains model provider settings, Bedrock region, and feature flags

### Environment Variables

Key environment variables passed to the containers:

| Variable | Source | Purpose |
|----------|--------|---------|
| `HERMES_HOME` | Hardcoded `/opt/data` | Data directory inside container |
| `SLACK_BOT_TOKEN` | SSM at runtime | Slack bot authentication |
| `SLACK_APP_TOKEN` | SSM at runtime | Slack Socket Mode connection |
| `SLACK_HOME_CHANNEL` | Terraform variable | Default channel for cron delivery |
| `SLACK_ALLOWED_USERS` | Terraform variable | Authorized Slack user IDs (empty = all) |
| `API_SERVER_ENABLED` | Terraform variable | Enable OpenAI-compatible API |
| `API_SERVER_KEY` | SSM at runtime | API server bearer token |

### Data Directory Structure

The persistent volume (`/var/lib/hermes` on host, `/opt/data` in container) holds:

| Path | Contents |
|------|----------|
| `config.yaml` | Agent configuration (rendered each boot) |
| `SOUL.md` | Agent personality (fetched from SSM) |
| `sessions/` | Conversation history |
| `memories/` | Persistent memory |
| `skills/` | Installed/created skills |
| `cron/` | Scheduled job definitions |
| `hooks/` | Event hook scripts |
| `logs/` | Session trajectory logs |
| `workspace/` | Working directory |

## Bedrock Integration

### Region and Model

- default region: `us-east-1`
- a single default model configured in `config.yaml`
- default model: `nvidia.nemotron-super-3-120b`
- callers can override both region and default model

### Model Discovery

- enabled by default via `bedrock_discovery_enabled` variable (default: `true`)
- allows Hermes to auto-detect available Bedrock models at runtime
- users can switch models interactively during sessions
- requires `bedrock:ListFoundationModels` and `bedrock:ListInferenceProfiles` IAM permissions

### Bedrock IAM Permissions

- `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` scoped to the configured model
- `bedrock:ListFoundationModels` and `bedrock:ListInferenceProfiles` (when discovery enabled)
- Authentication via EC2 instance role (standard AWS credential chain)

## Slack Integration

### Channel Scope

- Slack support is in scope for v1
- no other messaging channels are in scope for v1
- support one Slack workspace and one Slack bot

### Slack Mode

- use Slack Socket Mode only
- do not support inbound HTTP Request URL mode
- do not support Slack signing secret in v1

### Slack Configuration

- `SLACK_HOME_CHANNEL`: exposed as a Terraform variable for cron job delivery
- `SLACK_ALLOWED_USERS`: exposed as a Terraform variable; defaults to empty (all users allowed)

### Slack Secrets

Required secrets in v1:

- bot token (`SLACK_BOT_TOKEN`)
- app token (`SLACK_APP_TOKEN`)

Terraform provisions matching `SecureString` parameters with placeholder values; operators replace the values in Parameter Store. At runtime, the systemd wrapper fetches them from SSM and passes them as environment variables to Docker Compose.

## Logging and Observability

All container logs should be sent to CloudWatch Logs via the Docker `awslogs` log driver.

That includes:

- Hermes gateway logs
- Hermes dashboard logs

Bootstrap and EBS attachment logs are captured via journald on the instance. These are not shipped to CloudWatch -- they are only available via SSM session (`journalctl`) or the EC2 system log in the AWS console.

The module should create the CloudWatch log group and set retention to `30 days`.

The persistent EBS volume should not be used as the authoritative log store.

## Naming and Tagging

### Name Input

- module input `name` should be optional
- default `name`: `hermes`

### Tags

The module should apply stable, predictable tags consistently to all relevant resources.

At minimum, tags should include values equivalent to:

- `Name`
- `Project = hermes`
- `HermesDeployment = true`

These tags should be applied consistently to the ASG, launch template, instance, security group, log group, persistent EBS volume, and related resources so discovery logic and IAM scoping can rely on them.

The persistent EBS volume attach logic should use a stable deployment tag as its authoritative lookup handle rather than relying on instance IDs or mutable operator state.

For v1, the authoritative deployment discovery tag should be:

- `HermesDeployment = <name>`

with `name` defaulting to `hermes`. The persistent data volume should additionally carry a role tag so the boot logic can distinguish it cleanly:

- `HermesVolumeRole = data`

## Secure Hermes Posture

The v1 deployment should keep Hermes' enabled surface area conservative.

- dashboard access over SSM port forwarding
- Slack Socket Mode support
- Amazon Bedrock as the model backend
- optional OpenAI-compatible API server (disabled by default)
- no inbound webhook exposure
- no extra messaging channels
- no local-model hosting
- no additional optional integrations unless explicitly added later

If Hermes features or tools have to be chosen during implementation, the default should favor the smallest operational and security surface that still satisfies the agreed Bedrock-plus-Slack use case.

## Documentation Expectations

The repository should include operator-focused documentation for people who are not familiar with Hermes.

Working documentation structure:

- `README.md` for usage
- `docs/design.md` for architecture and design decisions
- `docs/runbook.md` for operations

The documentation should explain:

- what Hermes is
- what Hermes is in the context of this deployment
- a first-use operator quickstart for someone who has not used Hermes before
- why the design is single-node plus persistent EBS plus immutable EC2
- how the Docker Compose deployment works
- how Bedrock integration works
- how Slack Socket Mode is wired
- how SSM parameters are provisioned and how operators set token and SOUL.md values
- how to access the dashboard via SSM port forwarding
- what weekly instance refresh does
- how persistent volume reattachment works
- what to expect during rebuild and failure scenarios
- what is intentionally out of scope in v1

## Reference Design Principles

This module should follow the same general principles as the referenced `terraform-aws-softether-radius-vpn` module:

- configuration rendered through templated user data
- immutable, replaceable machine
- persistent externalized state
- clear operator-friendly docs
- minimal moving parts
- pragmatic use of Terraform modules

## Explicit In-Scope Items for v1

- single-node Hermes on EC2 via Docker Compose
- Amazon Linux 2023 `arm64`
- default instance type `t4g.medium`
- Auto Scaling Group with `desired=1`, `min=1`, `max=1`
- weekly ASG instance refresh on Sunday at `01:00 UTC`
- persistent encrypted gp3 EBS volume with safe reattachment
- no ingress
- Session Manager only
- localhost-bound dashboard on port 9119 (no authentication)
- optional API server on port 8642 (bearer token auth, disabled by default)
- Slack Socket Mode support with configurable `SLACK_HOME_CHANNEL` and `SLACK_ALLOWED_USERS`
- Bedrock with default model `nvidia.nemotron-super-3-120b` in `us-east-1`
- Bedrock model discovery enabled by default
- SSM `SecureString` parameters for secrets and SOUL.md
- Secret injection via systemd wrapper (secrets in process env, not on disk)
- CloudWatch Logs via Docker `awslogs` log driver
- operator-focused docs

## Explicit Out-of-Scope Items for v1

- `x86_64` support
- custom VPC creation
- SSH access
- multi-instance or HA deployment
- additional messaging channels
- generic config override escape hatches
- snapshot automation or backup scheduling
- Secrets Manager integration
- SSM State Manager ongoing maintenance
- customer-managed KMS key requirement
- aggressive automatic force-detach and volume steal behavior
