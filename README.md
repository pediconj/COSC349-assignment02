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

## 3. Cloud Configuration & Trust Boundaries

### Region & Resource Naming
- **Region:** The deployment is configured for the **US East (N. Virginia) `us-east-1`** region.
- **Naming Scheme:** All provisioned resources follow a `suresplit-*` or `SureSplit-*` prefix naming scheme to easily identify and manage associated assets (e.g., `suresplit-app-sg`, `suresplit-expense-notifications`, `SureSplit-Backend-API`).

### Trust Boundaries & Data Flows
The architecture enforces specific trust boundaries using the `suresplit-app-sg` security group:
1. **Public Entry:** The client browser exclusively interacts with the Nginx Frontend over HTTP Port 80.
2. **Internal Proxy:** Nginx routes API traffic downstream to the Backend API EC2 instance over Port 5000. The Backend trusts requests forwarded by the Frontend.
3. **Database Access:** The Backend API communicates with the RDS PostgreSQL instance over Port 5432 using explicit credential injection via environment variables during the systemd boot process. 
4. **Cloud API Interactions:** The Backend securely invokes AWS APIs to publish payloads to the SNS Topic (`suresplit-expense-notifications`), trusting the AWS IAM `LabInstanceProfile` instance profile attached to the Backend EC2 node.

---

## 4. Deployment Instructions

**Expected Deployment Time:** ~5 minutes.

### Prerequisites
- Terraform >= v1.0.0
- Active AWS Academy Learner Lab credentials loaded in `~/.aws/credentials`

### Step 1: Deploying the Application
Navigate to the terraform directory, initialize the provider, and apply the configuration. Terraform will automatically inject the application code into the boot scripts.
```bash
cd terraform
terraform init
terraform apply -auto-approve
```

### Step 2: Verification
Once Terraform finishes, it will output the `frontend_public_ip`, `api_public_ip`, and `rds_endpoint`. Wait approximately 2–3 minutes for the `user_data` boot scripts to finish installing packages and starting services.

To verify the deployment, run the automated workflow test script from the root of the repository:
```bash
# Ensure you are in the project root
chmod +x tests/test_workflow.sh
./tests/test_workflow.sh <frontend_public_ip>
```
If successful, the script will sequentially validate API health, RDS reads/writes, and dynamic group creations.

### Step 3: Redeployment & Teardown
If you make changes to the infrastructure or the application code in `app.py` or `index.html`, redeploy by running:
```bash
terraform apply -auto-approve
```

To entirely remove the deployment and halt all cloud costs:
```bash
terraform destroy -auto-approve
```