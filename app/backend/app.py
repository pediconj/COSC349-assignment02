import os
import time
import boto3
import psycopg2
from flask import Flask, jsonify, request

app = Flask(__name__)

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_NAME = os.environ.get("DB_NAME", "splitwise")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "Password123!")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")

def ensure_tables_exist():
    for attempt in range(15):
        try:
            conn = psycopg2.connect(
                host=DB_HOST, database=DB_NAME, user=DB_USER, password=DB_PASSWORD, connect_timeout=5
            )
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
        except Exception:
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
        except Exception:
            conn.rollback()
            cur.close()
            conn.close()
            return jsonify({"error": "Group already exists or database error"}), 400

    cur.execute("SELECT id, name, members FROM groups ORDER BY id DESC;")
    rows = cur.fetchall()
    groups_list = [{"id": r[0], "name": r[1], "members": [m.strip() for m in r[2].split(",") if m.strip()]} for r in rows]
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
        expenses.append({"id": e_id, "paid_by": paid_by, "amount": amt, "description": desc, "created_at": created})
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
            msg = "SureSplit Notification: New expense of $" + str(amount) + " for '" + description + "' paid by " + paid_by + " in " + group_name + "."
            sns.publish(TopicArn=SNS_TOPIC_ARN, Message=msg, Subject="SureSplit Expense Added")
        except Exception as e:
            print("SNS publish error:", e)

    return jsonify({"status": "success", "expense_id": expense_id}), 201

if __name__ == "__main__":
    ensure_tables_exist()
    app.run(host="0.0.0.0", port=5000)
