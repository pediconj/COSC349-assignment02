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

# 1. Security Group for Web & API Instances
resource "aws_security_group" "app_sg" {
  name        = "splitwise-app-sg"
  description = "Allow HTTP, API, and SSH access"

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

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 2. Managed Cloud Service: AWS SNS Topic
resource "aws_sns_topic" "expense_notifications" {
  name = "splitwise-expense-notifications"
}

# 3. Managed Storage: AWS RDS PostgreSQL Instance
resource "aws_db_instance" "postgres_db" {
  allocated_storage    = 20
  engine               = "postgres"
  engine_version       = "15"
  instance_class       = "db.t3.micro"
  db_name              = "splitwise"
  username             = "postgres"
  password             = "Password123!" # In production, pass as secure variable
  skip_final_snapshot  = true
  publicly_accessible = true
}

# 4. Compute Instance: Backend API Server
resource "aws_instance" "backend_api" {
  ami                  = "ami-0c7217cdde317cfec" # Amazon Linux 2023 AMI in us-east-1
  instance_type        = "t2.micro"
  iam_instance_profile = "LabInstanceProfile" # AWS Academy standard profile
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y python3 python3-pip git
              pip3 install flask psycopg2-binary boto3
              
              # Set Environment Variables
              export DB_HOST="${aws_db_instance.postgres_db.address}"
              export DB_NAME="splitwise"
              export DB_USER="postgres"
              export DB_PASSWORD="Password123!"
              export SNS_TOPIC_ARN="${aws_sns_topic.expense_notifications.arn}"
              
              # Pull and run API code
              mkdir /app && cd /app
              # Initialize DB table
              python3 -c "
              import psycopg2
              conn = psycopg2.connect(host='$DB_HOST', dbname='$DB_NAME', user='$DB_USER', password='$DB_PASSWORD')
              cur = conn.cursor()
              cur.execute('CREATE TABLE IF NOT EXISTS expenses (id SERIAL PRIMARY KEY, group_id VARCHAR(50), paid_by_user VARCHAR(50), amount NUMERIC(10,2), description TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);')
              conn.commit()
              cur.close()
              conn.close()
              "
              EOF

  tags = {
    Name = "Splitwise-Backend-API"
  }
}

# 5. Compute Instance: Frontend Web Server
resource "aws_instance" "frontend_web" {
  ami                  = "ami-0c7217cdde317cfec"
  instance_type        = "t2.micro"
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  tags = {
    Name = "Splitwise-Frontend-Web"
  }
}

output "api_public_ip" {
  value = aws_instance.backend_api.public_ip
}

output "frontend_public_ip" {
  value = aws_instance.frontend_web.public_ip
}

output "rds_endpoint" {
  value = aws_db_instance.postgres_db.endpoint
}
