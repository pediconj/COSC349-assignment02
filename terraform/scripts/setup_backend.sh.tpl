#!/bin/bash
exec > /var/log/user_data.log 2>&1
set -x

systemctl stop unattended-upgrades.service || true
systemctl disable unattended-upgrades.service || true
systemctl mask unattended-upgrades.service || true

pkill -9 -f apt-get || true
pkill -9 -f dpkg || true

rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock* /var/cache/apt/archives/lock* || true
dpkg --configure -a || true

export DEBIAN_FRONTEND=noninteractive
for i in {1..10}; do
  apt-get update -y && apt-get install -y python3-flask python3-psycopg2 python3-boto3 && break
  sleep 5
done

mkdir -p /app
cat << 'PYTHON_APP' > /app/app.py
${app_code}
PYTHON_APP

cat << SERVICE > /etc/systemd/system/suresplit.service
[Unit]
Description=SureSplit Flask API
Wants=network-online.target
After=network-online.target

[Service]
User=root
WorkingDirectory=/app
Environment="DB_HOST=${db_host}"
Environment="DB_NAME=splitwise"
Environment="DB_USER=postgres"
Environment="DB_PASSWORD=Password123!"
Environment="SNS_TOPIC_ARN=${sns_topic_arn}"
ExecStart=/usr/bin/python3 /app/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable suresplit.service
systemctl start suresplit.service
