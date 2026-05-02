# Operator Runbook

## First-Time Setup

### 1. Enable Bedrock Model Access

Before deploying, enable access to the Bedrock model(s) you plan to use:

1. Go to the [Amazon Bedrock console](https://console.aws.amazon.com/bedrock/) in the configured region (default: us-east-1)
2. Navigate to **Model access** in the left sidebar
3. Request access to the configured model (default inference profile: `us.anthropic.claude-haiku-4-5-20251001-v1:0` in the Bedrock console / model access)
4. Wait for access to be granted (usually immediate for most models)

### 2. Choose Messaging Channels

The module requires **at least one** channel: Slack (`slack_enabled`, default `true`) and/or email (`email_enabled`, default `false`). Both use **outbound-only** patterns—no inbound HTTP endpoints or public URLs for the messaging adapters (Slack Socket Mode; email via IMAP/SMTP from the instance).

### 3. Slack App (when `slack_enabled = true`)

Skip this section if you deploy **email-only** (`slack_enabled = false`, `email_enabled = true`).

1. Go to [Slack API Apps](https://api.slack.com/apps) and click **Create New App**
2. Choose **From scratch**, name it (e.g., "Hermes"), and select your workspace
3. Navigate to **Socket Mode** in the left sidebar and enable it
4. Generate an **App-Level Token** with the `connections:write` scope -- this is your App Token (xapp-...)
5. Navigate to **OAuth & Permissions** and add the required Bot Token Scopes:
   - `app_mentions:read`
   - `chat:write`
   - `im:history`
   - `im:read`
   - `im:write`
6. Install the app to your workspace
7. Copy the **Bot User OAuth Token** (xoxb-...) from the OAuth page

### 4. Email Mailbox (when `email_enabled = true`)

Hermes talks to your provider over **IMAP** (inbound) and **SMTP** (outbound). Use a **dedicated** mailbox for the agent (not your personal inbox). Typical steps:

1. Create or designate an email account for Hermes only.
2. Enable **IMAP** (and SMTP sending) per provider documentation.
3. If the provider uses 2FA (e.g. Gmail), create an **app password**—that value becomes `EMAIL_PASSWORD` in SSM, not your normal login password.
4. Decide **allowed senders** (`email_allowed_users` in Terraform). An empty list keeps Hermes default behavior (pairing codes); it does **not** set open-by-default email. To allow **any** sender, set `email_allow_all_users = true` only with deliberate risk acceptance (see variable description).
5. Set Terraform variables: `email_address`, `email_imap_host`, `email_smtp_host`, `email_home_address`, optional `email_imap_port` / `email_smtp_port` (defaults 993 / 587), `email_poll_interval`, `email_skip_attachments`, etc.

Authoritative upstream behavior and provider examples: [Hermes Email setup](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/email).

**Security group:** When `email_enabled`, the module opens outbound TCP on `email_imap_port` and `email_smtp_port` to `0.0.0.0/0`. If you override ports in Terraform, egress matches those values.

### 5. Deploy

```bash
terraform init
terraform apply
```

Terraform creates SSM parameters as follows (default prefix `/hermes`; adjust if `ssm_parameter_prefix` differs):

| Parameter path | When | Initial value |
|----------------|------|----------------|
| `<prefix>/slack/bot_token` | `slack_enabled` | Placeholder; **overwrite** before relying on Slack |
| `<prefix>/slack/app_token` | `slack_enabled` | Placeholder; **overwrite** before relying on Slack |
| `<prefix>/email/password` | `email_enabled` | Placeholder; **overwrite** with app password |
| `<prefix>/soul_md` | Always | Placeholder; set personality |
| `<prefix>/api_server_key` | `api_server_enabled` | Auto-generated |

If parameters already existed before Terraform managed them, import using the **indexed** addresses (Slack resources use `count`):

```bash
terraform import 'aws_ssm_parameter.slack_bot_token[0]' '/hermes/slack/bot_token'
terraform import 'aws_ssm_parameter.slack_app_token[0]' '/hermes/slack/app_token'
```

Use your actual parameter names if `ssm_parameter_prefix` is not `/hermes`.

**Terraform state migration (Slack `count`):** If you already had live infrastructure from a version where Slack SSM resources had no `count` index, use `terraform state mv` so addresses match the current module—see [Upgrading: Slack SSM Resources Now Use `count`](#upgrading-slack-ssm-resources-now-use-count). That is different from `terraform import` (for hand-created parameters in a fresh state).

### 6. Set Slack Token Values (`slack_enabled = true`)

When Slack is disabled, Terraform outputs for Slack parameters are `null`—use the known paths under `ssm_parameter_prefix` if you ever re-enable Slack manually. With `slack_enabled = true`, `terraform output -raw` is fine; if an output is `null`, `-raw` may print an empty line or the literal `null` depending on CLI version—prefer the explicit `/slack/bot_token` paths when automating across both modes.

```bash
BOT_PARAM="$(terraform output -raw slack_bot_token_ssm_parameter_name)"
APP_PARAM="$(terraform output -raw slack_app_token_ssm_parameter_name)"

aws ssm put-parameter \
  --name "$BOT_PARAM" \
  --type SecureString \
  --value "xoxb-your-bot-token-here" \
  --overwrite

aws ssm put-parameter \
  --name "$APP_PARAM" \
  --type SecureString \
  --value "xapp-your-app-token-here" \
  --overwrite
```

If the instance already started with placeholders, restart Hermes after updating tokens (see [Updating Slack Tokens](#updating-slack-tokens)).

### 7. Set Email Password (`email_enabled = true`)

There is **no** Terraform output for the email password parameter name (by design). Use:

`<ssm_parameter_prefix>/email/password`

Example with default prefix:

```bash
aws ssm put-parameter \
  --name "/hermes/email/password" \
  --type SecureString \
  --value "your-app-password-here" \
  --overwrite
```

Use spaces or hex format exactly as your provider issued it. Restart Hermes after changing (see [Updating Email Password](#updating-email-password)).

### 8. Set SOUL.md

The SOUL.md file defines the agent's personality and system prompt. Set it via SSM:

```bash
SOUL_PARAM="$(terraform output -raw soul_md_ssm_parameter_name)"

aws ssm put-parameter \
  --name "$SOUL_PARAM" \
  --type SecureString \
  --value "You are a helpful AI assistant called Hermes." \
  --overwrite
```

For longer content, use a file:

```bash
aws ssm put-parameter \
  --name "$SOUL_PARAM" \
  --type SecureString \
  --value "file://soul.md" \
  --overwrite
```

Restart Hermes after updating (trigger instance refresh or restart via SSM session).

## Day-to-Day Operations

### Accessing the Dashboard

The Hermes dashboard is bound to `127.0.0.1:9119` and is not publicly accessible. Use SSM port forwarding:

```bash
# Find instance ID
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$(terraform output -raw asg_name)" \
  --query "AutoScalingGroups[0].Instances[0].InstanceId" \
  --output text)

# Start port forwarding
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["9119"],"localPortNumber":["9119"]}'
```

Then open `http://localhost:9119` in your browser. No authentication is needed -- the dashboard has no built-in auth and relies on localhost binding for access control.

### Getting a Shell on the Instance

```bash
aws ssm start-session --target "$INSTANCE_ID"
```

### Checking Service Status

From an SSM session:

```bash
# Check Docker Compose services
cd /opt/hermes
docker compose ps

# Follow gateway logs
docker compose logs -f hermes-gateway

# Follow dashboard logs
docker compose logs -f hermes-dashboard

# Check bootstrap logs
journalctl -t hermes-bootstrap

# Check EBS attach logs
journalctl -t hermes-ebs
```

### Viewing CloudWatch Logs

Logs are shipped to CloudWatch under the log group `/hermes/<name>` (default: `/hermes/hermes`) via the Docker `awslogs` log driver:

| Log Stream | Content |
|-----------|---------|
| `hermes-gateway` | Gateway service logs |
| `hermes-dashboard` | Dashboard service logs |

## Weekly Instance Refresh

An EventBridge Scheduler triggers an ASG instance refresh weekly (default: Sunday 01:00 UTC). This:

1. Launches a new instance with the latest AMI and fresh configuration
2. The new instance discovers and attaches the persistent EBS volume
3. The old instance is terminated after the new one is healthy

### What to Expect

- Brief downtime (a few minutes) while the new instance boots, pulls the Docker image, and starts Hermes
- All Hermes state (sessions, memories, skills) is preserved on the EBS volume
- **Slack:** With `slack_enabled`, the Socket Mode connection reconnects automatically after the new instance starts
- **Email:** After restart, the Hermes email adapter typically **re-tests IMAP/SMTP**, marks **existing inbox messages as seen**, then polls for **new** mail only—so you should not see duplicate processing of old messages across refreshes; there is still a short gap while the new instance boots
- No operator intervention needed for normal refreshes

### Triggering a Manual Refresh

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "$(terraform output -raw asg_name)" \
  --strategy Rolling \
  --preferences '{"MinHealthyPercentage":0}'
```

## Troubleshooting

### Instance Fails to Start

1. Check bootstrap logs via SSM session: `journalctl -t hermes-bootstrap`. If SSM is not yet available (instance still booting), check the **EC2 system log** in the AWS console (Actions > Monitor and troubleshoot > Get system log).
2. Common issues:
   - **Slack placeholders** (`slack_enabled`): Ensure you ran `put-parameter --overwrite` for both Slack parameters with real `xoxb-` / `xapp-` tokens, then restart the containers
   - **Email password placeholder** (`email_enabled`): Set `<prefix>/email/password` and restart; verify IMAP/SMTP hosts and ports in Terraform match the provider
   - **Email blocked by security group**: Confirm `email_enabled` is true and outbound rules include your `email_imap_port` / `email_smtp_port`; misconfigured ports in Terraform cause mismatched SG vs Hermes
   - **Bedrock access not enabled**: Check model access in the Bedrock console
   - **EBS volume stuck in `in-use`**: Previous instance may not have fully terminated; the script waits up to 5 minutes then fails safely
   - **Docker image pull failed**: Check network connectivity and that the image tag exists

### Email-Specific Issues

| Symptom | Things to check |
|---------|------------------|
| IMAP/SMTP errors at startup | Hosts, ports, TLS expectations (993/587 defaults), app password, IMAP enabled at provider |
| No replies received | `email_allowed_users` includes sender; spam folder; only one gateway instance running |
| Authentication failures | App password vs normal password (Gmail requires app password + 2FA) |

See upstream [Email troubleshooting](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/email#troubleshooting).

### EBS Volume Won't Attach

The boot script refuses to force-detach a volume. If a volume is stuck:

1. Check if the old instance is still running: `aws ec2 describe-instances --instance-ids <old-id>`
2. If the instance is terminated but volume is still `in-use`, manually detach:
   ```bash
   aws ec2 detach-volume --volume-id <vol-id>
   ```
3. The ASG will automatically retry by launching a new instance

### Hermes Containers Won't Start

From an SSM session:

```bash
# Check container status
cd /opt/hermes
docker compose ps -a

# Check gateway logs
docker compose logs hermes-gateway --tail 50

# Check dashboard logs
docker compose logs hermes-dashboard --tail 50

# Check the rendered config
cat /var/lib/hermes/config.yaml

# Check the compose file
cat /opt/hermes/docker-compose.yml

# Verify the image was pulled
docker images | grep hermes-agent

# Optional one-shot diagnostics (SSM presence only; never prints secrets)
sudo /opt/hermes/hermes-diagnose.sh
```

### Updating Hermes Version

1. Change `hermes_version` in your Terraform configuration
2. Apply: `terraform apply`
3. The launch template updates with new user data
4. Trigger an instance refresh or wait for the next scheduled refresh

## Updating Slack Tokens

Only applies when `slack_enabled = true`. Parameter **names** are managed by Terraform; **values** are updated outside Terraform (`lifecycle.ignore_changes` on values).

```bash
BOT_PARAM="$(terraform output -raw slack_bot_token_ssm_parameter_name)"
APP_PARAM="$(terraform output -raw slack_app_token_ssm_parameter_name)"

aws ssm put-parameter \
  --name "$BOT_PARAM" \
  --type SecureString \
  --value "xoxb-new-token" \
  --overwrite

aws ssm put-parameter \
  --name "$APP_PARAM" \
  --type SecureString \
  --value "xapp-new-token" \
  --overwrite
```

Then restart the service (trigger instance refresh or restart via SSM session):

```bash
# Via SSM session on the instance:
cd /opt/hermes
docker compose restart
```

## Updating Email Password

When `email_enabled = true`, update `<prefix>/email/password` (default `/hermes/email/password`):

```bash
aws ssm put-parameter \
  --name "/hermes/email/password" \
  --type SecureString \
  --value "new-app-password" \
  --overwrite
```

Then restart Hermes (same as Slack—`docker compose restart` from `/opt/hermes` via SSM, or trigger an instance refresh).

## Updating SOUL.md

```bash
SOUL_PARAM="$(terraform output -raw soul_md_ssm_parameter_name)"

aws ssm put-parameter \
  --name "$SOUL_PARAM" \
  --type SecureString \
  --value "Your new personality prompt here" \
  --overwrite
```

Then restart:

```bash
# Via SSM session:
cd /opt/hermes
docker compose restart
```

Or trigger an instance refresh to pick it up on next boot.

## Upgrading: Slack SSM Resources Now Use `count`

This section is the **Terraform state migration** path for Slack parameters after the module started using `count` on those resources. It is **not** the same as `terraform import` for operator-created parameters (see **§ 5. Deploy** above).

If you deployed this module **before** Slack parameters used Terraform `count`, move state so existing AWS parameters map to the new addresses:

```bash
terraform state mv 'aws_ssm_parameter.slack_bot_token' 'aws_ssm_parameter.slack_bot_token[0]'
terraform state mv 'aws_ssm_parameter.slack_app_token' 'aws_ssm_parameter.slack_app_token[0]'
```

Then run `terraform plan`—there should be no unintended destruction of those parameters.
