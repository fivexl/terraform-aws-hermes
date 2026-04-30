[Unit]
Description=Hermes AI agent (Docker Compose)
Documentation=https://github.com/nousresearch/hermes-agent
After=local-fs.target docker.service network-online.target
Wants=network-online.target
Requires=docker.service
RequiresMountsFor=${data_path}

[Service]
Type=simple
ExecStart=${compose_dir}/hermes-start.sh
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
