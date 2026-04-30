#!/usr/bin/env bash
# Hermes startup wrapper.
# Fetches secrets from SSM, exports them as env vars, fetches SOUL.md,
# then exec's docker compose. Secrets stay in process memory only.

set -euo pipefail

REGION="${region}"
DATA_PATH="${data_path}"
COMPOSE_DIR="${compose_dir}"

ssm_get() {
  local name="$1"
  aws ssm get-parameter \
    --name "$name" \
    --with-decryption \
    --region "$REGION" \
    --query 'Parameter.Value' \
    --output text
}

IMAGE=$(tr -d '\n\r' <"$COMPOSE_DIR/.image")

# Container UID/GID for volume ownership and Compose interpolation.
# Bypass image ENTRYPOINT (it logs bundled-skills sync) so we only get numeric ids.
HERMES_UID=$(docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'id -u hermes' | tr -d '\r\n')
HERMES_GID=$(docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'id -g hermes' | tr -d '\r\n')
if [[ ! "$HERMES_UID" =~ ^[0-9]+$ || ! "$HERMES_GID" =~ ^[0-9]+$ ]]; then
  echo "warn: id hermes failed (uid='$HERMES_UID' gid='$HERMES_GID'); trying image Config.User" >&2
  ugs=$(docker image inspect "$IMAGE" --format '{{.Config.User}}' 2>/dev/null | tr -d '\r\n')
  if [[ "$ugs" =~ ^[0-9]+:[0-9]+$ ]]; then
    HERMES_UID=$${ugs%%:*}
    HERMES_GID=$${ugs##*:}
  elif [[ "$ugs" =~ ^[0-9]+$ ]]; then
    HERMES_UID=$ugs
    HERMES_GID=$ugs
  else
    echo "warn: Config.User='$ugs' not usable; falling back to 10000:10000" >&2
    HERMES_UID=10000
    HERMES_GID=10000
  fi
fi
if [[ ! "$HERMES_UID" =~ ^[0-9]+$ || ! "$HERMES_GID" =~ ^[0-9]+$ ]]; then
  HERMES_UID=10000
  HERMES_GID=10000
fi
export HERMES_UID HERMES_GID

# Ensure persistent volume is owned by the container user.
chown -R "$HERMES_UID:$HERMES_GID" "$DATA_PATH"

# Render SOUL.md from SSM into the data volume on every start.
SOUL_MD=$(ssm_get "${ssm_soul_md_path}")
printf '%s' "$SOUL_MD" > "$DATA_PATH/SOUL.md"
chown "$HERMES_UID:$HERMES_GID" "$DATA_PATH/SOUL.md"
unset SOUL_MD

# Fetch secrets and export to environment for docker compose interpolation.
SLACK_BOT_TOKEN=$(ssm_get "${ssm_slack_bot_token_path}")
SLACK_APP_TOKEN=$(ssm_get "${ssm_slack_app_token_path}")
export SLACK_BOT_TOKEN SLACK_APP_TOKEN

# Pass-through Slack tuning (may be empty, which is fine).
export SLACK_HOME_CHANNEL="${slack_home_channel}"
export SLACK_ALLOWED_USERS="${slack_allowed_users}"

%{ if slack_gateway_allow_all_users ~}
export GATEWAY_ALLOW_ALL_USERS=true
%{ else ~}
export GATEWAY_ALLOW_ALL_USERS=false
%{ endif ~}

%{ if api_server_enabled ~}
API_SERVER_KEY=$(ssm_get "${ssm_api_server_key_path}")
export API_SERVER_KEY
%{ endif ~}

exec docker compose -f "$COMPOSE_DIR/docker-compose.yml" up
