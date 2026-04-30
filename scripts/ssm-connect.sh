#!/usr/bin/env bash
# Open an interactive shell on the Hermes EC2 instance via SSM Session Manager.
#
# Instance discovery (first match wins). Terraform is not used.
#   1) Argument: instance ID (e.g. i-0abc...)
#   2) Env HERMES_INSTANCE_ID
#   3) Env HERMES_ASG_NAME — describe Auto Scaling group (e.g. hermes-asg)
#   4) EC2 describe-instances: tag HermesDeployment=<HERMES_DEPLOYMENT_NAME> (default: hermes)
#
# Usage:
#   ./scripts/ssm-connect.sh
#   ./scripts/ssm-connect.sh i-0123456789abcdef0
#   HERMES_ASG_NAME=hermes-asg ./scripts/ssm-connect.sh
#   HERMES_DEPLOYMENT_NAME=prod ./scripts/ssm-connect.sh   # tag HermesDeployment=prod

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=hermes-ssm-lib.sh
source "$ROOT/scripts/hermes-ssm-lib.sh"

hermes_require_cmd aws

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [i-INSTANCE_ID]" >&2
  exit 1
fi

INSTANCE_ID="$(hermes_resolve_target_instance_id "${1:-}")"

echo "Starting SSM session to $INSTANCE_ID" >&2
exec aws ssm start-session --target "$INSTANCE_ID"
