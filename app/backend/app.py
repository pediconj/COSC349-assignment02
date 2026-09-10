import os
import boto3
import psycopg2
from flask import Flask, jsonify, request

app = Flask(__name__)

# Fetch database credentials from environment variables set by Terraform/EC2
DB_HOST = os.getenv("DB_HOST", "localhost")
DB_NAME = os.getenv("DB_NAME", "splitwise")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", "postgres")
SNS_TOPIC_ARN = os.getenv("SNS_TOPIC_ARN", "")

def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST, database=DB_NAME, user=DB_USER, password=DB_PASSWORD
    )

@app.route("/health", methods=["GET"])
def health_check():
    return jsonify({"status": "healthy"}), 200

@app.route("/expenses", methods=["POST"])
def add_expense():
    data = request.json
    group_id = data.get("group_id")
    paid_by = data.get("paid_by")
    amount = data.get("amount")
    description = data.get("description")

    # 1. Write expense to Managed Storage (RDS PostgreSQL)
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO expenses (group_id, paid_by_user, amount, description) VALUES (%s, %s, %s, %s) RETURNING id;",
        (group_id, paid_by, amount, description)
    )
    expense_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    conn.close()

    # 2. Trigger Managed Cloud Service (AWS SNS Notification)
    if SNS_TOPIC_ARN:
        sns = boto3.client("sns", region_name="us-east-1")
        msg = f"New expense added: ${amount} for '{description}' by User {paid_by}."
        sns.publish(TopicArn=SNS_TOPIC_ARN, Message=msg, Subject="New Expense Notification")

    return jsonify({"status": "success", "expense_id": expense_id}), 201

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
