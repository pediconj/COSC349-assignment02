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
  name        = "suresplit-app-sg"
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
  name = "suresplit-expense-notifications"
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

  user_data_base64 = base64encode(templatefile("${path.module}/scripts/setup_backend.sh.tpl", {
    db_host       = aws_db_instance.postgres_db.address
    sns_topic_arn = aws_sns_topic.expense_notifications.arn
    app_code      = file("${path.module}/../app/backend/app.py")
  }))

  tags = {
    Name = "SureSplit-Backend-API"
  }
}

# 5. Compute Instance: Frontend Web Server
resource "aws_instance" "frontend_web" {
  ami                  = "ami-0c7217cdde317cfec"
  instance_type        = "t2.micro"
  key_name             = "vockey"
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  user_data_base64 = base64encode(templatefile("${path.module}/scripts/setup_frontend.sh.tpl", {
    backend_ip = aws_instance.backend_api.public_ip
    html_code  = file("${path.module}/../app/frontend/index.html")
  }))

  tags = {
    Name = "SureSplit-Frontend-Web"
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
