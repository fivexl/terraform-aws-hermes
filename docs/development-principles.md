# Development Principles

## Purpose

This document captures the engineering and security principles agreed for the Hermes Terraform module. It is separate from the design brief so it can be used as an implementation checklist and review standard.

## Infrastructure Principles

### Immutable Infrastructure

- Treat the EC2 instance as disposable.
- Rebuild machines instead of repairing them manually.
- Keep persistent state off the instance root filesystem.
- Render configuration from Terraform and bootstrap inputs on each boot rather than preserving machine-local config indefinitely.
- Use Auto Scaling Group replacement and scheduled refresh instead of in-place mutation as the normal lifecycle.

### Persistent State Separation

- Persist only true application state across instance replacement.
- Keep Hermes data/state on a dedicated EBS volume.
- Do not use the persistent volume as a generic dumping ground for logs, ad hoc config, or operational drift.
- Preserve and reattach the data volume during EC2 replacement.
- Prefer safe reattachment behavior over aggressive force-detach behavior.

### Self-Contained Module

- The module should create the resources required for a working deployment.
- Avoid requiring callers to hand-assemble core IAM, EC2, logging, and storage pieces outside the module.
- Accept external inputs where appropriate, but keep the deployment operationally coherent out of the box.

### Prefer Proven Upstream Modules

- Prefer established open source Terraform modules from `terraform-aws-modules` where they fit naturally.
- Do not add wrapper complexity for its own sake.
- Reuse upstream modules when they reduce maintenance cost without obscuring behavior.

## Security Principles

### Least Privilege

- Grant only the permissions the instance actually needs.
- Scope SSM access to the exact parameter paths or ARNs needed.
- Scope Bedrock permissions to the configured model.
- Scope CloudWatch Logs permissions to the module-created log group only.
- Scope EC2 permissions for volume discovery and attachment as tightly as AWS realistically allows.
- Avoid broad wildcard permissions unless there is no practical narrower option.

### Defense in Depth

- Do not rely on a single control when layered controls are practical.
- Use `SecureString` for all secrets.
- Keep ingress fully disabled even when the instance has a public IP.
- Inject secrets via process environment, not persistent files on the data volume.

### Minimize Exposure

- No SSH.
- No public dashboard exposure.
- Bind the Hermes dashboard to `127.0.0.1` only.
- Use SSM port forwarding for dashboard access.
- Prefer outbound-only integration patterns such as Slack Socket Mode.
- Avoid inbound webhooks unless there is a deliberate future requirement.
- Keep the API server disabled by default.

### Conservative Feature Posture

- Enable only the features needed for the agreed use case.
- Keep v1 focused on Hermes dashboard access, Slack Socket Mode, and Bedrock-backed inference.
- Avoid extra channels, extra integrations, and optional surfaces unless intentionally added later.
- If a feature choice is ambiguous, prefer the smaller security and operational surface.

### Secure Defaults

- Enforce IMDSv2 only.
- Use the lowest practical metadata hop limit.
- Encrypt root and data volumes by default.
- Use no SSH key pair.
- Restrict security group egress to the smallest practical set of ports.

## Container Principles

### Pinned Images

- Pin the Hermes Docker image to an exact version tag.
- Never use the `latest` tag.
- Treat image version changes as infrastructure changes requiring a new deployment.

### Minimal Container Surface

- Use `network_mode: host` to avoid unnecessary port mapping complexity.
- Run containers as a non-root user (Hermes' built-in `hermes` user).
- Query the container for UID/GID rather than hardcoding values.
- Use Docker's restart policy (`unless-stopped`) for container-level recovery.

### Secret Isolation

- Do not bake secrets into container images.
- Do not write secrets to any filesystem (persistent volume or root).
- Inject secrets as environment variables via the systemd wrapper.
- Secrets live only in process memory -- the systemd unit exports them and exec's Docker Compose.

## Dependency and Build Principles

### Pin Everything Important

- Pin the Hermes Docker image version exactly.
- Pin runtime expectations rather than floating to whatever happens to be newest.
- Prefer deterministic bootstrap behavior over "latest at boot" behavior.

### Avoid Unnecessary Drift

- Do not run broad in-place OS upgrades during bootstrap.
- Install only the exact packages needed (Docker, Docker Compose, AWS CLI).
- Prefer rebuilding onto a fresh AMI over patching a long-lived machine in place.
- Keep bootstrap idempotent and predictable.

### Prefer Platform-Native Components

- Use Amazon Linux 2023 standard AMIs.
- Prefer platform-provided tooling when it satisfies requirements, such as the preinstalled AWS CLI.
- Avoid adding external installers unless they are needed for reproducibility or missing functionality.

## Operational Principles

### Safety Over Convenience for Stateful Recovery

- Do not automatically force-detach a persistent EBS volume from a potentially still-running instance.
- Prefer waiting and failing safely over risking filesystem corruption.
- Make failure modes visible in logs rather than hiding them behind dangerous automation.

### Logging and Observability

- Ship container logs to CloudWatch Logs via the Docker `awslogs` log driver.
- Capture bootstrap and storage-attachment logs via journald.
- Do not rely on ephemeral instance state for retained operational visibility.
- Keep enough logging to diagnose boot, attach, auth, and startup failures.

### Simple Access Pattern

- Use Session Manager as the single administrative access path.
- Keep the operator workflow simple and document it clearly.
- Prefer one obvious way to access the system rather than multiple competing admin paths.

### Clear Documentation

- Document not just how to deploy, but why the system is shaped this way.
- Provide operator-oriented documentation for people unfamiliar with Hermes.
- Document secret setup, dashboard access, SOUL.md configuration, rebuild behavior, and expected failure modes.

## Configuration Principles

### Opinionated by Default

- Keep the module contract focused and opinionated in v1.
- Expose inputs where they are genuinely useful.
- Avoid broad "escape hatch" configuration surfaces unless there is a concrete need.
- Favor hardcoded secure defaults over premature configurability.

### Runtime Secret Resolution

- Keep secret values out of Terraform-managed plaintext configuration.
- Resolve secrets at runtime from SSM Parameter Store through the instance role.
- Inject secrets as environment variables via a systemd wrapper.
- Fail fast on missing or invalid secret material rather than partially starting insecurely.

### Stable Naming and Discovery

- Use stable names, tags, and parameter path conventions.
- Ensure boot logic can discover the persistent data volume deterministically.
- Avoid tying stateful recovery logic to ephemeral instance identifiers.

## Cost and Pragmatism Principles

### Cost-Aware Defaults

- Prefer the default VPC/default subnet pattern when it avoids unnecessary NAT gateway cost.
- Prefer cost-efficient Graviton instance types where compatible.
- Prefer SSM Parameter Store over Secrets Manager when the feature set is sufficient.
- Keep the deployment single-node unless there is a proven need for more.

### Practical Security

- Choose the most secure setup that still fits the operational model.
- Do not introduce expensive or complex controls that are unnecessary for the agreed risk profile.
- When choosing between elegant theory and reliable operation, prefer the approach that remains understandable and supportable.

## Review Standard

Changes to this module should be evaluated against these questions:

- Does this preserve the disposable-instance model?
- Does this keep persistent state isolated and protected?
- Does this reduce or expand permissions, exposure, or drift?
- Is the behavior deterministic and reproducible?
- Does this add configuration surface without clear need?
- Does this preserve operator clarity?
- Does this keep costs aligned with the intended deployment model?
- Are secrets kept out of persistent storage and container images?
