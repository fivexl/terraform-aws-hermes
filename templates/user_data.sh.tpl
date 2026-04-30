#!/usr/bin/env bash
# Hermes bootstrap: Docker, EBS attach/mount, Compose config, systemd service.

set -euo pipefail

exec > >(systemd-cat -t hermes-bootstrap) 2>&1

echo "=== Hermes bootstrap started ==="
echo "Deployment: ${volume_tag_name}"
echo "Region: ${region}"
echo "AZ: ${az}"

for cmd in aws; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "FATAL: required command '$cmd' not found"
    exit 1
  fi
done

TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
INSTANCE_ID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
echo "Instance ID: $INSTANCE_ID"

echo "Installing Docker..."
# AL2023 default repos ship docker but not docker-compose-plugin; install Compose v2 CLI plugin manually (pinned).
dnf install -y docker xfsprogs

DOCKER_COMPOSE_VERSION="2.29.7"
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  aarch64) COMPOSE_ARCH="aarch64" ;;
  x86_64) COMPOSE_ARCH="x86_64" ;;
  *) echo "FATAL: unsupported architecture for docker compose: $ARCH_RAW"; exit 1 ;;
esac
COMPOSE_URL="https://github.com/docker/compose/releases/download/v$${DOCKER_COMPOSE_VERSION}/docker-compose-linux-$${COMPOSE_ARCH}"
COMPOSE_DST="/usr/local/lib/docker/cli-plugins/docker-compose"
mkdir -p "$(dirname "$COMPOSE_DST")"
curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_DST"
chmod +x "$COMPOSE_DST"

systemctl enable --now docker

echo "Waiting for Docker daemon..."
for _ in $(seq 1 30); do
  if docker info &>/dev/null; then
    break
  fi
  sleep 2
done
if ! docker info &>/dev/null; then
  echo "FATAL: Docker daemon not reachable after install"
  exit 1
fi

if ! docker compose version &>/dev/null; then
  echo "FATAL: docker compose CLI plugin not working after install"
  exit 1
fi

mkdir -p "${compose_dir}"

cat > "${compose_dir}/docker-compose.yml" <<'COMPOSEEOF'
${hermes_compose}
COMPOSEEOF

echo -n "${hermes_image}" > "${compose_dir}/.image"

cat > "${compose_dir}/hermes-start.sh" <<'STARTEOF'
${hermes_start_script}
STARTEOF
chmod 755 "${compose_dir}/hermes-start.sh"

cat > "${compose_dir}/hermes-diagnose.sh" <<'DIAGEOF'
${hermes_diagnose_script}
DIAGEOF
chmod 755 "${compose_dir}/hermes-diagnose.sh"

cat > /etc/systemd/system/hermes.service <<'SVCEOF'
${hermes_service}
SVCEOF

ebs_log() { echo "$*" | systemd-cat -t hermes-ebs; echo "$*"; }

ebs_log "Discovering persistent data volume..."

VOLUME_ID=$(aws ec2 describe-volumes \
  --region "${region}" \
  --filters \
    "Name=tag:HermesDeployment,Values=${volume_tag_name}" \
    "Name=tag:HermesVolumeRole,Values=data" \
    "Name=availability-zone,Values=${az}" \
  --query "Volumes[0].VolumeId" \
  --output text)

if [[ -z "$VOLUME_ID" || "$VOLUME_ID" == "None" ]]; then
  ebs_log "FATAL: no persistent data volume found with tags HermesDeployment=${volume_tag_name}, HermesVolumeRole=data in ${az}"
  exit 1
fi

ebs_log "Found volume: $VOLUME_ID"

MAX_WAIT=300
WAIT_INTERVAL=10
WAITED=0

while true; do
  VOL_STATE=$(aws ec2 describe-volumes \
    --region "${region}" \
    --volume-ids "$VOLUME_ID" \
    --query "Volumes[0].State" \
    --output text)

  if [[ "$VOL_STATE" == "available" ]]; then
    ebs_log "Volume is available"
    break
  elif [[ "$VOL_STATE" == "in-use" ]]; then
    ATTACHED_INSTANCE=$(aws ec2 describe-volumes \
      --region "${region}" \
      --volume-ids "$VOLUME_ID" \
      --query "Volumes[0].Attachments[0].InstanceId" \
      --output text)

    if [[ "$ATTACHED_INSTANCE" == "$INSTANCE_ID" ]]; then
      ebs_log "Volume is already attached to this instance"
      break
    fi

    if [[ $WAITED -ge $MAX_WAIT ]]; then
      ebs_log "FATAL: volume $VOLUME_ID is still attached to $ATTACHED_INSTANCE after $${MAX_WAIT}s. Refusing to force-detach."
      exit 1
    fi

    ebs_log "Volume is in-use by $ATTACHED_INSTANCE, waiting for clean detach ($${WAITED}s/$${MAX_WAIT}s)..."
    sleep "$WAIT_INTERVAL"
    WAITED=$((WAITED + WAIT_INTERVAL))
  else
    ebs_log "FATAL: unexpected volume state: $VOL_STATE"
    exit 1
  fi
done

CURRENT_STATE=$(aws ec2 describe-volumes \
  --region "${region}" \
  --volume-ids "$VOLUME_ID" \
  --query "Volumes[0].Attachments[?InstanceId=='$INSTANCE_ID'].State" \
  --output text)

if [[ -z "$CURRENT_STATE" || "$CURRENT_STATE" == "None" ]]; then
  ebs_log "Attaching volume $VOLUME_ID to $INSTANCE_ID as /dev/xvdf..."
  aws ec2 attach-volume \
    --region "${region}" \
    --volume-id "$VOLUME_ID" \
    --instance-id "$INSTANCE_ID" \
    --device /dev/xvdf

  ebs_log "Waiting for device to appear..."
  DEVICE_WAIT=0
  DEVICE_MAX=120
  DEVICE=""

  while [[ $DEVICE_WAIT -lt $DEVICE_MAX ]]; do
    VOLID_CLEAN=$(echo "$VOLUME_ID" | sed 's/-//')
    DEVICE=$(readlink -f "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$VOLID_CLEAN" 2>/dev/null || true)

    if [[ -b "$DEVICE" ]]; then
      ebs_log "Device appeared: $DEVICE"
      break
    fi

    sleep 5
    DEVICE_WAIT=$((DEVICE_WAIT + 5))
  done

  if [[ -z "$DEVICE" || ! -b "$DEVICE" ]]; then
    ebs_log "FATAL: device for volume $VOLUME_ID did not appear after $${DEVICE_MAX}s"
    exit 1
  fi
else
  ebs_log "Volume already attached (state: $CURRENT_STATE), discovering device..."
  VOLID_CLEAN=$(echo "$VOLUME_ID" | sed 's/-//')
  DEVICE=$(readlink -f "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$VOLID_CLEAN" 2>/dev/null || true)

  if [[ -z "$DEVICE" || ! -b "$DEVICE" ]]; then
    ebs_log "FATAL: cannot find block device for attached volume $VOLUME_ID"
    exit 1
  fi
  ebs_log "Found existing device: $DEVICE"
fi

mkdir -p "${data_path}"

FSTYPE=$(blkid -o value -s TYPE "$DEVICE" 2>/dev/null || true)

if [[ -z "$FSTYPE" ]]; then
  ebs_log "Volume is blank, creating XFS filesystem..."
  mkfs.xfs "$DEVICE"
  ebs_log "XFS filesystem created"
elif [[ "$FSTYPE" != "xfs" ]]; then
  ebs_log "FATAL: volume has unexpected filesystem type: $FSTYPE (expected xfs or blank). Refusing to reformat."
  exit 1
fi

ebs_log "Mounting $DEVICE at ${data_path}..."
mount "$DEVICE" "${data_path}"

VOL_UUID=$(blkid -s UUID -o value "$DEVICE")
if [[ -z "$VOL_UUID" ]]; then
  ebs_log "FATAL: could not read XFS UUID from $DEVICE"
  exit 1
fi
if ! grep -qF "$VOL_UUID" /etc/fstab 2>/dev/null; then
  echo "UUID=$VOL_UUID ${data_path} xfs defaults,nofail 0 2" >> /etc/fstab
fi

cat > "${data_path}/config.yaml" <<'HERMESCFGEOF'
${hermes_config}
HERMESCFGEOF

echo "Pulling Hermes image ${hermes_image}..."
docker pull "${hermes_image}"

# Image ENTRYPOINT prints startup noise; use explicit shell entrypoint so we only capture numeric ids.
HERMES_UID=$(docker run --rm --entrypoint /bin/sh "${hermes_image}" -c 'id -u hermes' | tr -d '\r\n')
HERMES_GID=$(docker run --rm --entrypoint /bin/sh "${hermes_image}" -c 'id -g hermes' | tr -d '\r\n')
if [[ ! "$HERMES_UID" =~ ^[0-9]+$ || ! "$HERMES_GID" =~ ^[0-9]+$ ]]; then
  echo "warn: id hermes failed (uid='$HERMES_UID' gid='$HERMES_GID'); trying image Config.User"
  ugs=$(docker image inspect "${hermes_image}" --format '{{.Config.User}}' 2>/dev/null | tr -d '\r\n')
  if [[ "$ugs" =~ ^[0-9]+:[0-9]+$ ]]; then
    HERMES_UID=$${ugs%%:*}
    HERMES_GID=$${ugs##*:}
  elif [[ "$ugs" =~ ^[0-9]+$ ]]; then
    HERMES_UID=$ugs
    HERMES_GID=$ugs
  else
    echo "warn: Config.User='$ugs' not usable; falling back to 10000:10000"
    HERMES_UID=10000
    HERMES_GID=10000
  fi
fi
if [[ ! "$HERMES_UID" =~ ^[0-9]+$ || ! "$HERMES_GID" =~ ^[0-9]+$ ]]; then
  HERMES_UID=10000
  HERMES_GID=10000
fi
chown -R "$HERMES_UID:$HERMES_GID" "${data_path}"
ebs_log "Volume mounted and ownership set to container user $HERMES_UID:$HERMES_GID"

systemctl daemon-reload
systemctl enable hermes.service
systemctl start hermes.service

echo "=== Hermes bootstrap completed ==="
