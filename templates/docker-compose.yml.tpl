services:
  hermes-gateway:
    image: ${image}
    container_name: hermes-gateway
    network_mode: host
    restart: unless-stopped
    user: "$${HERMES_UID}:$${HERMES_GID}"
    volumes:
      - ${data_path}:/opt/data
    environment:
      HERMES_HOME: /opt/data
      AWS_REGION: ${region}
      SLACK_BOT_TOKEN: $${SLACK_BOT_TOKEN}
      SLACK_APP_TOKEN: $${SLACK_APP_TOKEN}
      SLACK_HOME_CHANNEL: $${SLACK_HOME_CHANNEL}
      SLACK_ALLOWED_USERS: $${SLACK_ALLOWED_USERS}
      # Set by hermes-start.sh from Terraform slack_allowed_users (open vs restricted).
      GATEWAY_ALLOW_ALL_USERS: $${GATEWAY_ALLOW_ALL_USERS:-false}
%{ if api_server_enabled ~}
      API_SERVER_ENABLED: "true"
      API_SERVER_KEY: $${API_SERVER_KEY}
%{ endif ~}
    command: ["gateway", "run"]
    logging:
      driver: awslogs
      options:
        awslogs-region: ${region}
        awslogs-group: ${log_group_name}
        awslogs-stream: hermes-gateway

  hermes-dashboard:
    image: ${image}
    container_name: hermes-dashboard
    network_mode: host
    restart: unless-stopped
    user: "$${HERMES_UID}:$${HERMES_GID}"
    volumes:
      - ${data_path}:/opt/data
    environment:
      HERMES_HOME: /opt/data
      AWS_REGION: ${region}
    command: ["dashboard", "--host", "127.0.0.1", "--no-open"]
    logging:
      driver: awslogs
      options:
        awslogs-region: ${region}
        awslogs-group: ${log_group_name}
        awslogs-stream: hermes-dashboard
