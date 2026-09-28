# SureSplit — Automated Cloud Infrastructure (COSC349 Assignment 2)

SureSplit is a fully automated, multi-tier expense sharing web application deployed on Amazon Web Services (AWS) using Terraform Infrastructure as Code (IaC).

## 1. System Architecture Overview

The system consists of three main tiers:
- **Web Frontend Tier:** An EC2 instance running Nginx configured as a reverse proxy on Port 80, serving a single-page web application.
- **Backend API Tier:** An EC2 instance running a Flask Python API managed via systemd on Port 5000.
- **Managed Cloud Services:**
  - **AWS RDS PostgreSQL (v15):** Relational storage engine persisting group structures and user expense histories.
  - **AWS SNS Topic:** Asynchronous notification service publishing event alerts whenever an expense is created.

## 2. Key Architectural Justifications

### Infrastructure as Code (Terraform)
- **Declarative Provisioning:** Terraform manages the full resource lifecycle, ensuring complete environment reproducibility without manual console interventions.
- **Decoupled Application Templates:** Boot scripts (`setup_backend.sh.tpl` and `setup_frontend.sh.tpl`) inject application source files (`app.py`, `index.html`) using `templatefile()`, separating infrastructure configuration from application logic.

### Managed Cloud Services
- **AWS RDS PostgreSQL:** Selected over an on-instance database to ensure database reliability, automated failover capabilities, storage decoupling, and transactional integrity for multi-user financial balances.
- **AWS SNS:** Provides an event-driven publish/subscribe model that decouples real-time expense processing from external alert channels.

### Compute & Networking Strategy
- **Nginx Reverse Proxy:** Resolves browser Cross-Origin Resource Sharing (CORS) security restrictions and network port blocks by proxying all `/api/*` traffic internally over HTTP Port 80 to the backend API.
- **Systemd Service Lifecycle:** The Flask API is configured as a systemd background daemon (`suresplit.service`) with auto-restart policies to maintain API availability.

### Automated Boot Hardening
- **Package Lock Mitigations:** Boot scripts explicitly isolate Ubuntu `apt` and `dpkg` locks caused by background `unattended-upgrades` services during instance startup.
- **Database Socket Retry Loops:** Backend startup scripts incorporate polling loops to wait for RDS database socket readiness before binding the application service.

---

## 3. Deployment Instructions

### Prerequisites
- Terraform >= v1.0.0
- Active AWS Academy Learner Lab credentials (`~/.aws/credentials`)

### Execution
1. Navigate to the terraform directory:
   ```bash
   cd terraform