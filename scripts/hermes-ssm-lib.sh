#!/usr/bin/env bash
# Shared helpers for Hermes SSM scripts. Source from repo scripts only.
# No Terraform required — discovery uses the AWS CLI only.

set -euo pipefail

hermes_require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

# Returns 0 if $1 is an integer TCP port in [1, 65535].
hermes_valid_tcp_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 && "$1" -le 65535 ]]
}

# AWS ASG names: up to 255 chars; letters, digits, . _ - /
hermes_valid_asg_name_for_aws() {
  local n="$1"
  [[ ${#n} -ge 1 && ${#n} -le 255 ]] || return 1
  [[ "$n" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
}

# Matches Terraform variable \"name\" (tag HermesDeployment on instances).
hermes_valid_deployment_name() {
  local n="$1"
  [[ ${#n} -ge 1 && ${#n} -le 128 ]] || return 1
  [[ "$n" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
}

# Prefer InService instance; otherwise first instance in the ASG.
hermes_resolve_instance_id_from_asg() {
  local asg_name="$1"
  local iid

  if ! hermes_valid_asg_name_for_aws "$asg_name"; then
    echo "error: refusing to call AWS with invalid Auto Scaling group name (length/chars): ${asg_name:0:120}" >&2
    exit 1
  fi

  iid=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$asg_name" \
    --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'] | [0].InstanceId" \
    --output text)

  if [[ -z "$iid" || "$iid" == "None" ]]; then
    iid=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$asg_name" \
      --query "AutoScalingGroups[0].Instances[0].InstanceId" \
      --output text)
  fi

  if [[ -z "$iid" || "$iid" == "None" ]]; then
    echo "error: no EC2 instance found in Auto Scaling group: $asg_name (wrong name, scaling to zero, or still launching?)" >&2
    exit 1
  fi

  printf '%s' "$iid"
}

# Resolve via EC2 tag HermesDeployment=<deployment> (same tag the module sets on instances).
hermes_resolve_instance_id_by_deployment_tag() {
  local deployment="${HERMES_DEPLOYMENT_NAME:-hermes}"
  local raw
  local -a ids=()

  if ! hermes_valid_deployment_name "$deployment"; then
    echo "error: HERMES_DEPLOYMENT_NAME must be 1-128 chars [A-Za-z0-9_-] (Terraform \"name\")." >&2
    exit 1
  fi

  raw=$(aws ec2 describe-instances \
    --filters \
      "Name=tag:HermesDeployment,Values=$deployment" \
      "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text)

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^i-[a-fA-F0-9]+$ ]] || continue
    ids+=("$line")
  done < <(printf '%s' "$raw" | tr '\t' '\n' | sort -u)

  if [[ ${#ids[@]} -eq 0 ]]; then
    echo "error: no running/pending instance with tag HermesDeployment=$deployment in this account/region." >&2
    echo "Set HERMES_INSTANCE_ID, or HERMES_ASG_NAME (e.g. ${deployment}-asg), or fix AWS_PROFILE/AWS_REGION." >&2
    exit 1
  fi

  if [[ ${#ids[@]} -gt 1 ]]; then
    echo "error: multiple instances (${#ids[@]}) match HermesDeployment=$deployment: ${ids[*]}" >&2
    echo "Set HERMES_INSTANCE_ID or HERMES_ASG_NAME to pick one." >&2
    exit 1
  fi

  printf '%s' "${ids[0]}"
}

# Order: positional i-..., HERMES_INSTANCE_ID, HERMES_ASG_NAME + ASG API, else EC2 tag HermesDeployment (HERMES_DEPLOYMENT_NAME).
hermes_resolve_target_instance_id() {
  if [[ -n "${1:-}" ]]; then
    printf '%s' "$1"
    return 0
  fi
  if [[ -n "${HERMES_INSTANCE_ID:-}" ]]; then
    printf '%s' "$HERMES_INSTANCE_ID"
    return 0
  fi

  hermes_require_cmd aws

  if [[ -n "${HERMES_ASG_NAME:-}" ]]; then
    if ! hermes_valid_asg_name_for_aws "${HERMES_ASG_NAME}"; then
      echo "error: HERMES_ASG_NAME must be 1-255 chars [A-Za-z0-9._/-] only; got: ${HERMES_ASG_NAME:0:120}" >&2
      exit 1
    fi
    hermes_resolve_instance_id_from_asg "${HERMES_ASG_NAME}"
    return 0
  fi

  hermes_resolve_instance_id_by_deployment_tag
}
