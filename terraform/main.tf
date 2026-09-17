terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# 1. Security Group
resource "aws_security_group" "app_sg" {
  name        = "splitwise-app-sg"
  description = "Allow HTTP, API, SSH, and PostgreSQL access"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 2. Managed Cloud Service: SNS Topic
resource "aws_sns_topic" "expense_notifications" {
  name = "splitwise-expense-notifications"
}

# 3. Managed Storage: RDS PostgreSQL
resource "aws_db_instance" "postgres_db" {
  allocated_storage      = 20
  engine                 = "postgres"
  engine_version         = "15"
  instance_class         = "db.t3.micro"
  db_name                = "splitwise"
  username               = "postgres"
  password               = "Password123!"
  skip_final_snapshot    = true
  publicly_accessible    = true
  vpc_security_group_ids = [aws_security_group.app_sg.id]
}

# 4. Compute Instance: Backend API Server
resource "aws_instance" "backend_api" {
  ami                  = "ami-0c7217cdde317cfec"
  instance_type        = "t2.micro"
  iam_instance_profile = "LabInstanceProfile"
  key_name             = "vockey"
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  user_data_base64 = base64encode(<<-EOF
#!/bin/bash
exec > /var/log/user_data.log 2>&1
set -x

# 1. Stop background updates locking dpkg
systemctl stop unattended-upgrades.service || true
systemctl disable unattended-upgrades.service || true
systemctl mask unattended-upgrades.service || true

pkill -9 -f apt-get || true
pkill -9 -f dpkg || true

rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock* /var/cache/apt/archives/lock* || true
dpkg --configure -a || true

# 2. Install dependencies with retry loop
export DEBIAN_FRONTEND=noninteractive
for i in {1..10}; do
  apt-get update -y && apt-get install -y python3-flask python3-psycopg2 python3-boto3 && break
  sleep 5
done

# 3. Write Flask Application
mkdir -p /app
cat << 'APP' > /app/app.py
import os, time, boto3, psycopg2
from flask import Flask, jsonify, request

app = Flask(__name__)

DB_HOST = "${aws_db_instance.postgres_db.address}"
DB_NAME = "splitwise"
DB_USER = "postgres"
DB_PASSWORD = "Password123!"
SNS_TOPIC_ARN = "${aws_sns_topic.expense_notifications.arn}"

def ensure_table_exists():
    for attempt in range(15):
        try:
            conn = psycopg2.connect(host=DB_HOST, database=DB_NAME, user=DB_USER, password=DB_PASSWORD, connect_timeout=5)
            cur = conn.cursor()
            cur.execute('''
                CREATE TABLE IF NOT EXISTS expenses (
                    id SERIAL PRIMARY KEY,
                    group_id VARCHAR(50),
                    paid_by_user VARCHAR(50),
                    amount NUMERIC(10,2),
                    description TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                );
            ''')
            conn.commit()
            cur.close()
            conn.close()
            return True
        except Exception as e:
            time.sleep(3)
    return False

@app.route("/health", methods=["GET"])
def health_check():
    return jsonify({"status": "healthy"}), 200

@app.route("/expenses", methods=["POST"])
def add_expense():
    ensure_table_exists()
    data = request.json or {}
    group_id = data.get("group_id", "default")
    paid_by = data.get("paid_by", "anon")
    amount = data.get("amount", 0)
    description = data.get("description", "expense")

    conn = psycopg2.connect(host=DB_HOST, database=DB_NAME, user=DB_USER, password=DB_PASSWORD, connect_timeout=5)
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO expenses (group_id, paid_by_user, amount, description) VALUES (%s, %s, %s, %s) RETURNING id;",
        (group_id, paid_by, amount, description)
    )
    expense_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    conn.close()

    if SNS_TOPIC_ARN:
        try:
            sns = boto3.client("sns", region_name="us-east-1")
            msg = f"New expense added: $${amount} for '{description}' by {paid_by}."
            sns.publish(TopicArn=SNS_TOPIC_ARN, Message=msg, Subject="New Expense Notification")
        except Exception as e:
            print("SNS publish error:", e)

    return jsonify({"status": "success", "expense_id": expense_id}), 201

if __name__ == "__main__":
    ensure_table_exists()
    app.run(host="0.0.0.0", port=5000)
APP

# 4. Create systemd unit
cat << 'SERVICE' > /etc/systemd/system/splitwise.service
[Unit]
Description=Splitwise Flask API
Wants=network-online.target
After=network-online.target

[Service]
User=root
WorkingDirectory=/app
ExecStart=/usr/bin/python3 /app/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable splitwise.service
systemctl start splitwise.service
EOF
  )

  tags = {
    Name = "Splitwise-Backend-API"
  }
}

# 5. Compute Instance: Frontend Web Server
resource "aws_instance" "frontend_web" {
  ami                  = "ami-0c7217cdde317cfec"
  instance_type        = "t2.micro"
  key_name             = "vockey"
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  tags = {
    Name = "Splitwise-Frontend-Web"
  }
}

# Outputs
output "api_public_ip" {
  value = aws_instance.backend_api.public_ip
}

output "frontend_public_ip" {
  value = aws_instance.frontend_web.public_ip
}

output "rds_endpoint" {
  value = aws_db_instance.postgres_db.endpoint
}
