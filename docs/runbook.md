# Operator Runbook

## First-Time Setup

### 1. Enable Bedrock Model Access

Before deploying, enable access to the Bedrock model(s) you plan to use:

1. Go to the [Amazon Bedrock console](https://console.aws.amazon.com/bedrock/) in the configured region (default: us-east-1)
2. Navigate to **Model access** in the left sidebar
3. Request access to the configured model (default: `nvidia.nemotron-super-3-120b`)
4. Wait for access to be granted (usually immediate for most models)

### 2. Create Slack App

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

### 3. Deploy

```bash
terraform init
terraform apply
```

Terraform creates all SSM parameters:

- **Slack tokens** -- parameters exist at `<prefix>/slack/bot_token` and `<prefix>/slack/app_token` with placeholder values. You **must** overwrite them with real tokens before Hermes can talk to Slack (next section).
- **SOUL.md** -- parameter exists at `<prefix>/soul_md` with a placeholder value. Set it to define the agent's personality.
- **API server key** (when `api_server_enabled = true`) -- auto-generated at `<prefix>/api_server_key`.

Default prefix is `/hermes`.

If you already created those SSM parameters by hand before this behavior existed, import them instead of failing on "already exists":

```bash
terraform import 'aws_ssm_parameter.slack_bot_token' '/hermes/slack/bot_token'
terraform import 'aws_ssm_parameter.slack_app_token' '/hermes/slack/app_token'
```

Use your actual parameter names if `ssm_parameter_prefix` is not `/hermes`.

### 4. Set Slack Token Values

Overwrite the placeholders with the tokens from step 2. Use Terraform outputs so the names stay correct if you change `ssm_parameter_prefix`:

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

### 5. Set SOUL.md

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
- Slack connection reconnects automatically after the new instance starts
- No operator intervention needed

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
   - **Slack still using placeholders**: Ensure you ran `put-parameter --overwrite` for both Slack parameters with real `xoxb-` / `xapp-` tokens, then restart the containers
   - **Bedrock access not enabled**: Check model access in the Bedrock console
   - **EBS volume stuck in `in-use`**: Previous instance may not have fully terminated; the script waits up to 5 minutes then fails safely
   - **Docker image pull failed**: Check network connectivity and that the image tag exists

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
```

### Updating Hermes Version

1. Change `hermes_version` in your Terraform configuration
2. Apply: `terraform apply`
3. The launch template updates with new user data
4. Trigger an instance refresh or wait for the next scheduled refresh

## Updating Slack Tokens

Slack parameter **names** are managed by Terraform; **values** are always updated outside Terraform (Terraform ignores `value` changes on those resources).

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
