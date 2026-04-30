#!/usr/bin/env bash
# Port-forward the Hermes dashboard (127.0.0.1:REMOTE_PORT on the instance) to localhost.
#
# Same instance discovery as ssm-connect.sh (AWS CLI only; no Terraform).
#
# Usage:
#   ./scripts/ssm-dashboard-forward.sh
#   ./scripts/ssm-dashboard-forward.sh 19119                    # local port only (discover instance)
#   ./scripts/ssm-dashboard-forward.sh i-0abc1234567890abcd
#   ./scripts/ssm-dashboard-forward.sh i-0abc1234567890abcd 19119
#
# Env:
#   LOCAL_PORT, REMOTE_PORT — dashboard forwarding (defaults 9119)
#   HERMES_INSTANCE_ID, HERMES_ASG_NAME, HERMES_DEPLOYMENT_NAME — see ssm-connect.sh
#
# Then open http://localhost:<LOCAL_PORT> in your browser.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=hermes-ssm-lib.sh
source "$ROOT/scripts/hermes-ssm-lib.sh"

hermes_require_cmd aws

REMOTE_PORT="${REMOTE_PORT:-9119}"
LOCAL_PORT="${LOCAL_PORT:-9119}"

INSTANCE_OVERRIDE=""
if [[ "${1:-}" == i-* ]]; then
  INSTANCE_OVERRIDE="$1"
  shift
fi

if [[ -n "${1:-}" ]]; then
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    LOCAL_PORT="$1"
    shift
  else
    echo "error: expected local TCP port number, got: $1" >&2
    exit 1
  fi
fi

if [[ $# -gt 0 ]]; then
  echo "usage: $0 [i-INSTANCE_ID] [LOCAL_PORT]" >&2
  exit 1
fi

for v in LOCAL_PORT REMOTE_PORT; do
  if ! hermes_valid_tcp_port "${!v}"; then
    echo "error: $v must be an integer 1-65535, got: ${!v}" >&2
    exit 1
  fi
done

INSTANCE_ID="$(hermes_resolve_target_instance_id "$INSTANCE_OVERRIDE")"

echo "Port forwarding: localhost:${LOCAL_PORT} -> ${INSTANCE_ID}:127.0.0.1:${REMOTE_PORT} (dashboard)" >&2
echo "Open http://localhost:${LOCAL_PORT}" >&2

exec aws ssm start-session \
  --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "{\"portNumber\":[\"${REMOTE_PORT}\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
