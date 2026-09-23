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

# 2. Install dependencies
export DEBIAN_FRONTEND=noninteractive
for i in {1..10}; do
  apt-get update -y && apt-get install -y python3-flask python3-psycopg2 python3-boto3 && break
  sleep 5
done

# 3. Write SureSplit Flask Application
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

def ensure_tables_exist():
    for attempt in range(15):
        try:
            conn = psycopg2.connect(host=DB_HOST, database=DB_NAME, user=DB_USER, password=DB_PASSWORD, connect_timeout=5)
            cur = conn.cursor()
            cur.execute('''
                CREATE TABLE IF NOT EXISTS groups (
                    id SERIAL PRIMARY KEY,
                    name VARCHAR(100) UNIQUE NOT NULL,
                    members TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS expenses (
                    id SERIAL PRIMARY KEY,
                    group_name VARCHAR(100) NOT NULL,
                    paid_by VARCHAR(50) NOT NULL,
                    amount NUMERIC(10,2) NOT NULL,
                    description TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                );
            ''')
            conn.commit()

            cur.execute("SELECT COUNT(*) FROM groups;")
            if cur.fetchone()[0] == 0:
                cur.execute("INSERT INTO groups (name, members) VALUES (%s, %s);", ("Apartment 4B", "Jace, Alex, Sam"))
                cur.execute("INSERT INTO groups (name, members) VALUES (%s, %s);", ("Road Trip 2026", "Jace, Taylor, Morgan"))
                conn.commit()

            cur.close()
            conn.close()
            return True
        except Exception as e:
            time.sleep(3)
    return False

@app.after_request
def add_cors_headers(response):
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type,Authorization'
    response.headers['Access-Control-Allow-Methods'] = 'GET,POST,OPTIONS'
    return response

@app.route("/health", methods=["GET"])
def health_check():
    return jsonify({"status": "healthy"}), 200

@app.route("/groups", methods=["GET", "POST", "OPTIONS"])
def handle_groups():
    if request.method == "OPTIONS":
        return jsonify({"status": "ok"}), 200

    ensure_tables_exist()
    conn = psycopg2.connect(host=DB_HOST, database=DB_NAME, user=DB_USER, password=DB_PASSWORD, connect_timeout=5)
    cur = conn.cursor()

    if request.method == "POST":
        data = request.json or {}
        name = data.get("name", "").strip()
        members = data.get("members", "").strip()
        if not name or not members:
            cur.close()
            conn.close()
            return jsonify({"error": "Name and members required"}), 400
        try:
            cur.execute("INSERT INTO groups (name, members) VALUES (%s, %s) RETURNING id;", (name, members))
            group_id = cur.fetchone()[0]
            conn.commit()
            cur.close()
            conn.close()
            return jsonify({"status": "success", "id": group_id, "name": name}), 201
        except Exception as e:
            conn.rollback()
            cur.close()
            conn.close()
            return jsonify({"error": "Group already exists or database error"}), 400

    cur.execute("SELECT id, name, members FROM groups ORDER BY id DESC;")
    rows = cur.fetchall()
    groups_list = []
    for r in rows:
        m_list = [m.strip() for m in r[2].split(",") if m.strip()]
        groups_list.append({"id": r[0], "name": r[1], "members": m_list})
    cur.close()
    conn.close()
    return jsonify(groups_list), 200

@app.route("/groups/<path:group_name>", methods=["GET", "OPTIONS"])
def get_group_details(group_name):
    if request.method == "OPTIONS":
        return jsonify({"status": "ok"}), 200

    ensure_tables_exist()
    conn = psycopg2.connect(host=DB_HOST, database=DB_NAME, user=DB_USER, password=DB_PASSWORD, connect_timeout=5)
    cur = conn.cursor()

    cur.execute("SELECT id, name, members FROM groups WHERE name = %s;", (group_name,))
    group_row = cur.fetchone()
    if not group_row:
        cur.close()
        conn.close()
        return jsonify({"error": "Group not found"}), 404

    members = [m.strip() for m in group_row[2].split(",") if m.strip()]

    cur.execute("SELECT id, paid_by, amount, description, created_at FROM expenses WHERE group_name = %s ORDER BY id DESC;", (group_name,))
    expense_rows = cur.fetchall()

    expenses = []
    total_spent = 0.0
    balances = {m: 0.0 for m in members}
    num_members = len(members) if len(members) > 0 else 1

    for row in expense_rows:
        e_id, paid_by, amt, desc, created = row[0], row[1], float(row[2]), row[3], str(row[4])
        expenses.append({
            "id": e_id,
            "paid_by": paid_by,
            "amount": amt,
            "description": desc,
            "created_at": created
        })
        total_spent += amt

        share = amt / num_members
        for m in members:
            if m.lower() == paid_by.lower():
                balances[m] += (amt - share)
            else:
                balances[m] -= share

    cur.close()
    conn.close()
    return jsonify({
        "name": group_row[1],
        "members": members,
        "expenses": expenses,
        "total_spent": round(total_spent, 2),
        "balances": {m: round(b, 2) for m, b in balances.items()}
    }), 200

@app.route("/expenses", methods=["POST", "OPTIONS"])
def add_expense():
    if request.method == "OPTIONS":
        return jsonify({"status": "ok"}), 200

    ensure_tables_exist()
    data = request.json or {}
    group_name = data.get("group_name", "default")
    paid_by = data.get("paid_by", "anon")
    amount = float(data.get("amount", 0))
    description = data.get("description", "expense")

    conn = psycopg2.connect(host=DB_HOST, database=DB_NAME, user=DB_USER, password=DB_PASSWORD, connect_timeout=5)
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO expenses (group_name, paid_by, amount, description) VALUES (%s, %s, %s, %s) RETURNING id;",
        (group_name, paid_by, amount, description)
    )
    expense_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    conn.close()

    if SNS_TOPIC_ARN:
        try:
            sns = boto3.client("sns", region_name="us-east-1")
            msg = f"SureSplit Notification: New expense of $${amount:.2f} for '{description}' paid by {paid_by} in {group_name}."
            sns.publish(TopicArn=SNS_TOPIC_ARN, Message=msg, Subject="SureSplit Expense Added")
        except Exception as e:
            print("SNS publish error:", e)

    return jsonify({"status": "success", "expense_id": expense_id}), 201

if __name__ == "__main__":
    ensure_tables_exist()
    app.run(host="0.0.0.0", port=5000)
APP

# 4. Create systemd unit
cat << 'SERVICE' > /etc/systemd/system/splitwise.service
[Unit]
Description=SureSplit Flask API
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
    Name = "SureSplit-Backend-API"
  }
}

# 5. Compute Instance: Frontend Web Server with Reverse Proxy
resource "aws_instance" "frontend_web" {
  ami                  = "ami-0c7217cdde317cfec"
  instance_type        = "t2.micro"
  key_name             = "vockey"
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  user_data_base64 = base64encode(<<-EOF
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
  apt-get update -y && apt-get install -y nginx && break
  sleep 5
done

# Configure Nginx Reverse Proxy
cat << 'NGINX' > /etc/nginx/sites-available/default
server {
    listen 80 default_server;
    server_name _;

    root /var/www/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    location /api/ {
        proxy_pass http://${aws_instance.backend_api.public_ip}:5000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGINX

# Write SureSplit Frontend Single Page Web Application
cat << 'HTML' > /var/www/html/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SureSplit - Expense Sharing Made Simple</title>
    <style>
        :root { --primary: #10b981; --primary-dark: #059669; --bg: #f3f4f6; --card-bg: #ffffff; --text: #1f2937; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); margin: 0; padding: 0; }
        header { background: var(--card-bg); border-bottom: 1px solid #e5e7eb; padding: 16px 32px; display: flex; align-items: center; justify-content: space-between; }
        .logo { font-size: 24px; font-weight: 800; color: var(--primary-dark); cursor: pointer; }
        .container { max-width: 900px; margin: 32px auto; padding: 0 16px; }
        .card { background: var(--card-bg); border-radius: 12px; padding: 24px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.05); margin-bottom: 24px; }
        h2 { margin-top: 0; font-size: 20px; font-weight: 700; }
        .btn { background: var(--primary); color: white; border: none; padding: 10px 18px; border-radius: 8px; font-weight: 600; cursor: pointer; font-size: 14px; }
        .btn:hover { background: var(--primary-dark); }
        .btn-secondary { background: #e5e7eb; color: var(--text); margin-right: 8px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 16px; margin-top: 16px; }
        .group-card { background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px; padding: 16px; cursor: pointer; transition: transform 0.1s, border-color 0.1s; }
        .group-card:hover { transform: translateY(-2px); border-color: var(--primary); }
        .group-card h3 { margin: 0 0 8px 0; color: var(--primary-dark); }
        .members-text { font-size: 13px; color: #6b7280; }
        input, select { width: 100%; padding: 10px; margin: 8px 0 16px 0; border: 1px solid #d1d5db; border-radius: 6px; box-sizing: border-box; }
        .flex { display: flex; align-items: center; justify-content: space-between; }
        .badge { display: inline-block; padding: 4px 12px; border-radius: 9999px; font-weight: 600; font-size: 13px; }
        .badge-owed { background: #d1fae5; color: #065f46; }
        .badge-owes { background: #fee2e2; color: #991b1b; }
        .badge-settled { background: #f3f4f6; color: #4b5563; }
        .balance-item { display: flex; justify-content: space-between; align-items: center; padding: 12px 0; border-bottom: 1px solid #f3f4f6; }
        .balance-item:last-child { border-bottom: none; }
        .expense-item { display: flex; justify-content: space-between; align-items: center; padding: 12px; background: #f9fafb; border-radius: 6px; margin-bottom: 8px; }
        .hidden { display: none; }
    </style>
</head>
<body>
    <header>
        <div class="logo" onclick="showGroupList()">SureSplit</div>
        <div><button class="btn" onclick="toggleNewGroupForm()">+ New Group</button></div>
    </header>

    <div class="container">
        <!-- New Group Form Modal/Card -->
        <div id="new-group-card" class="card hidden">
            <h2>Create New SureSplit Group</h2>
            <input type="text" id="new-group-name" placeholder="Group Name (e.g. Summer Flat)">
            <input type="text" id="new-group-members" placeholder="Members comma-separated (e.g. Jace, Alex, Sam)">
            <button class="btn" onclick="createGroup()">Create Group</button>
            <button class="btn btn-secondary" onclick="toggleNewGroupForm()">Cancel</button>
        </div>

        <!-- Group List View -->
        <div id="group-list-view">
            <div class="card">
                <h2>Your Expense Groups</h2>
                <div id="groups-grid" class="grid">Loading groups...</div>
            </div>
        </div>

        <!-- Group Detail View -->
        <div id="group-detail-view" class="hidden">
            <button class="btn btn-secondary" onclick="showGroupList()">← Back to Groups</button>
            
            <div class="card" style="margin-top: 16px;">
                <div class="flex">
                    <div>
                        <h2 id="detail-group-name" style="margin: 0; font-size: 24px;">Group Details</h2>
                        <div id="detail-group-members" class="members-text" style="margin-top: 4px;"></div>
                    </div>
                    <div style="text-align: right;">
                        <span class="members-text">Total Group Spent</span>
                        <div id="detail-total-spent" style="font-size: 22px; font-weight: 800; color: var(--primary-dark);">$0.00</div>
                    </div>
                </div>
            </div>

            <div class="card">
                <h2>Group Balance Breakdown</h2>
                <div id="balances-container">Loading balances...</div>
            </div>

            <div class="card">
                <h2>Add New Expense</h2>
                <div id="expense-form-status" style="margin-bottom: 8px; font-weight: 600;"></div>
                <input type="text" id="expense-desc" placeholder="Expense Description (e.g. Weekly Groceries)">
                <input type="number" step="0.01" id="expense-amount" placeholder="Amount ($)">
                <label class="members-text">Paid By</label>
                <select id="expense-paid-by"></select>
                <button class="btn" onclick="submitExpense()">Add Expense</button>
            </div>

            <div class="card">
                <h2>Expense History</h2>
                <div id="expenses-history">No expenses recorded yet.</div>
            </div>
        </div>
    </div>

    <script>
        let currentGroup = null;

        async function fetchGroups() {
            try {
                const res = await fetch('/api/groups');
                const groups = await res.json();
                const grid = document.getElementById('groups-grid');
                grid.innerHTML = '';
                
                if (groups.length === 0) {
                    grid.innerHTML = '<p class="members-text">No groups found. Create one above!</p>';
                    return;
                }

                groups.forEach(g => {
                    const card = document.createElement('div');
                    card.className = 'group-card';
                    card.onclick = () => openGroupDetail(g.name);
                    card.innerHTML = '<h3>' + g.name + '</h3><div class="members-text">Members: ' + g.members.join(', ') + '</div>';
                    grid.appendChild(card);
                });
            } catch (err) {
                document.getElementById('groups-grid').innerText = 'Error loading groups.';
            }
        }

        async function createGroup() {
            const name = document.getElementById('new-group-name').value.trim();
            const members = document.getElementById('new-group-members').value.trim();
            if (!name || !members) return alert('Please enter both group name and members.');

            try {
                const res = await fetch('/api/groups', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ name: name, members: members })
                });
                if (res.ok) {
                    document.getElementById('new-group-name').value = '';
                    document.getElementById('new-group-members').value = '';
                    toggleNewGroupForm();
                    fetchGroups();
                } else {
                    alert('Error creating group.');
                }
            } catch (err) {
                alert('Connection error.');
            }
        }

        async function openGroupDetail(groupName) {
            currentGroup = groupName;
            document.getElementById('group-list-view').classList.add('hidden');
            document.getElementById('group-detail-view').classList.remove('hidden');
            document.getElementById('detail-group-name').innerText = groupName;

            try {
                const res = await fetch('/api/groups/' + encodeURIComponent(groupName));
                const data = await res.json();

                document.getElementById('detail-group-members').innerText = 'Members: ' + data.members.join(', ');
                document.getElementById('detail-total-spent').innerText = '$' + data.total_spent.toFixed(2);

                // Populate Paid By dropdown
                const select = document.getElementById('expense-paid-by');
                select.innerHTML = '';
                data.members.forEach(m => {
                    const opt = document.createElement('option');
                    opt.value = m;
                    opt.innerText = m;
                    select.appendChild(opt);
                });

                // Render Balances
                const balancesDiv = document.getElementById('balances-container');
                balancesDiv.innerHTML = '';
                Object.keys(data.balances).forEach(m => {
                    const bal = data.balances[m];
                    const item = document.createElement('div');
                    item.className = 'balance-item';
                    
                    let badgeClass = 'badge-settled';
                    let statusText = 'settled up';
                    if (bal > 0) {
                        badgeClass = 'badge-owed';
                        statusText = 'is owed $' + bal.toFixed(2);
                    } else if (bal < 0) {
                        badgeClass = 'badge-owes';
                        statusText = 'owes $' + Math.abs(bal).toFixed(2);
                    }

                    item.innerHTML = '<strong>' + m + '</strong><span class="badge ' + badgeClass + '">' + statusText + '</span>';
                    balancesDiv.appendChild(item);
                });

                // Render Expenses History
                const historyDiv = document.getElementById('expenses-history');
                historyDiv.innerHTML = '';
                if (data.expenses.length === 0) {
                    historyDiv.innerHTML = '<p class="members-text">No expenses added yet.</p>';
                } else {
                    data.expenses.forEach(e => {
                        const div = document.createElement('div');
                        div.className = 'expense-item';
                        div.innerHTML = '<div><strong>' + e.description + '</strong><br><span class="members-text">Paid by ' + e.paid_by + '</span></div><div style="font-weight:700;">$' + parseFloat(e.amount).toFixed(2) + '</div>';
                        historyDiv.appendChild(div);
                    });
                }
            } catch (err) {
                alert('Error loading group details.');
            }
        }

        async function submitExpense() {
            const desc = document.getElementById('expense-desc').value.trim();
            const amt = parseFloat(document.getElementById('expense-amount').value);
            const paidBy = document.getElementById('expense-paid-by').value;
            const statusDiv = document.getElementById('expense-form-status');

            if (!desc || isNaN(amt) || amt <= 0) {
                statusDiv.style.color = 'red';
                statusDiv.innerText = 'Please enter a valid description and amount.';
                return;
            }

            statusDiv.style.color = '#333';
            statusDiv.innerText = 'Submitting expense...';

            try {
                const res = await fetch('/api/expenses', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        group_name: currentGroup,
                        description: desc,
                        amount: amt,
                        paid_by: paidBy
                    })
                });

                if (res.ok) {
                    document.getElementById('expense-desc').value = '';
                    document.getElementById('expense-amount').value = '';
                    statusDiv.style.color = 'green';
                    statusDiv.innerText = 'Expense added successfully!';
                    setTimeout(() => { statusDiv.innerText = ''; }, 3000);
                    openGroupDetail(currentGroup);
                } else {
                    statusDiv.style.color = 'red';
                    statusDiv.innerText = 'Error submitting expense.';
                }
            } catch (err) {
                statusDiv.style.color = 'red';
                statusDiv.innerText = 'Connection error.';
            }
        }

        function showGroupList() {
            currentGroup = null;
            document.getElementById('group-detail-view').classList.add('hidden');
            document.getElementById('group-list-view').classList.remove('hidden');
            fetchGroups();
        }

        function toggleNewGroupForm() {
            document.getElementById('new-group-card').classList.toggle('hidden');
        }

        // Initialize on page load
        fetchGroups();
    </script>
</body>
</html>
HTML

systemctl restart nginx
EOF
  )

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
