#!/usr/bin/env bash
# Hermes EC2 one-shot diagnostics: paths, Docker, systemd, SSM presence (values never printed).
# Run: sudo /opt/hermes/hermes-diagnose.sh   (or ${compose_dir}/hermes-diagnose.sh)

set -uo pipefail

REGION="${region}"
DATA_PATH="${data_path}"
COMPOSE_DIR="${compose_dir}"

bar() { printf '%s\n' "================================================================================"; }

ssm_param_exists() {
  local name="$1"
  local n
  n=$(aws ssm describe-parameters \
    --region "$REGION" \
    --parameter-filters "Key=Name,Option=Equals,Values=$name" \
    --query 'length(Parameters)' \
    --output text 2>/dev/null || echo "0")
  if [[ "$n" == "1" ]]; then
    echo "  exists: $name"
  else
    echo "  MISSING or ListParameters denied: $name"
  fi
}

echo ""
bar
echo "Hermes diagnose  $(date -u +%Y-%m-%dT%H:%M:%SZ)  $(hostname)"
bar
echo "Compose dir: $COMPOSE_DIR"
echo "Data path:   $DATA_PATH"
echo "AWS region:  $REGION"
echo ""

echo "=== EC2 instance (IMDSv2) ==="
TOKEN=$(curl -sS -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
if [[ -n "$TOKEN" ]]; then
  for meta in instance-id instance-type local-ipv4 placement/availability-zone; do
    v=$(curl -sS -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" \
      "http://169.254.169.254/latest/meta-data/$meta" 2>/dev/null || echo "?")
    echo "  $meta: $v"
  done
else
  echo "  (IMDS token failed — not EC2 or IMDS blocked)"
fi
echo ""

echo "=== STS caller ==="
aws sts get-caller-identity --region "$REGION" --output text 2>&1 || true
echo ""

echo "=== Data volume mount ==="
findmnt "$DATA_PATH" 2>/dev/null || echo "  NOT MOUNTED: $DATA_PATH"
df -h "$DATA_PATH" 2>/dev/null || true
echo "  ownership (top-level): $(stat -c '%u:%g %U:%G' "$DATA_PATH" 2>/dev/null || stat -f '%u:%g' "$DATA_PATH" 2>/dev/null || echo '?')"
echo ""

echo "=== Pinned image ==="
if [[ -f "$COMPOSE_DIR/.image" ]]; then
  echo "  $(tr -d '\n\r' <"$COMPOSE_DIR/.image")"
else
  echo "  (missing $COMPOSE_DIR/.image)"
fi
echo ""

echo "=== Layout ==="
for f in "$COMPOSE_DIR/docker-compose.yml" "$COMPOSE_DIR/hermes-start.sh" "$COMPOSE_DIR/hermes-diagnose.sh" "$DATA_PATH/config.yaml" "$DATA_PATH/SOUL.md"; do
  if [[ -e "$f" ]]; then
    echo "  ok: $f"
  else
    echo "  MISSING: $f"
  fi
done
echo ""

echo "=== config.yaml (first 30 lines, secrets should not appear here) ==="
if [[ -f "$DATA_PATH/config.yaml" ]]; then
  head -n 30 "$DATA_PATH/config.yaml" | sed 's/^/  | /'
else
  echo "  (no file)"
fi
echo ""

echo "=== Docker ==="
command -v docker &>/dev/null && docker version --format '  client: {{.Client.Version}}  server: {{.Server.Version}}' 2>/dev/null || echo "  docker not installed or daemon down"
docker info &>/dev/null && echo "  daemon: reachable" || echo "  daemon: NOT reachable"
docker compose version 2>/dev/null | sed 's/^/  /' || echo "  docker compose: missing"
echo ""

echo "=== Images (hermes) ==="
docker image ls 2>/dev/null | grep -E 'REPOSITORY|nousresearch/hermes|hermes-agent' || docker image ls 2>/dev/null | head -n 8 || echo "  (docker image ls failed)"
echo ""

echo "=== Containers ==="
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || echo "  (docker ps failed)"
echo ""

echo "=== Compose ps (may warn on unset env if not sourced; still useful) ==="
if [[ -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
  (cd "$COMPOSE_DIR" && docker compose -f docker-compose.yml ps 2>&1) | sed 's/^/  /' || true
else
  echo "  (no compose file)"
fi
echo ""

echo "=== systemd hermes.service ==="
systemctl is-enabled hermes 2>/dev/null | sed 's/^/  enabled: /' || echo "  enabled: unknown"
systemctl is-active hermes 2>/dev/null | sed 's/^/  active: /' || echo "  active: unknown"
systemctl status hermes --no-pager -l 2>&1 | tail -n 25 | sed 's/^/  /'
echo ""

echo "=== Journal: hermes unit (last 40 lines) ==="
journalctl -u hermes -n 40 --no-pager 2>&1 | sed 's/^/  /'
echo ""

echo "=== Journal: hermes-bootstrap (last 20 lines) ==="
journalctl -t hermes-bootstrap -n 20 --no-pager 2>&1 | sed 's/^/  /'
echo ""

echo "=== Container logs (tail 12 each) ==="
for c in hermes-gateway hermes-dashboard; do
  bar
  echo "docker logs $c"
  docker logs "$c" 2>&1 | tail -n 12 | sed 's/^/  /' || echo "  (no such container or logs unavailable)"
done
echo ""

echo "=== SSM parameters (metadata only; token values never shown) ==="
ssm_param_exists "${ssm_slack_bot_token_path}"
ssm_param_exists "${ssm_slack_app_token_path}"
ssm_param_exists "${ssm_soul_md_path}"
%{ if api_server_enabled ~}
ssm_param_exists "${ssm_api_server_key_path}"
%{ endif ~}
echo ""

echo "=== Listening TCP ports (first 40) ==="
if command -v ss &>/dev/null; then
  ss -tlnp 2>/dev/null | head -n 40 | sed 's/^/  /'
else
  netstat -tlnp 2>/dev/null | head -n 40 | sed 's/^/  /' || echo "  (ss/netstat unavailable)"
fi
echo ""

bar
echo "Done. Re-run after fixes; collect this output when opening an issue."
bar
echo ""
