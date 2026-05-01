model:
  default: ${bedrock_model_id}
  provider: bedrock
bedrock:
  region: ${bedrock_region}
  discovery:
    enabled: ${bedrock_discovery_enabled}
%{ if email_enabled ~}
platforms:
  email:
    skip_attachments: ${email_skip_attachments}
%{ endif ~}
