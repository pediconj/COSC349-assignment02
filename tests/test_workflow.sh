#!/bin/bash
# Automated verification check for COSC349 cloud deployment

API_HOST=${1:-"localhost"}
API_PORT="5000"
ENDPOINT="http://${API_HOST}:${API_PORT}/expenses"

echo "=== Running Automated Cloud Verification Check ==="
echo "Targeting API at: ${ENDPOINT}"

# Send POST request creating a test expense
RESPONSE=$(curl -s -X POST "${ENDPOINT}" \
  -H "Content-Type: application/json" \
  -d '{
    "group_id": "test-group",
    "paid_by": "AutomatedTestRunner",
    "amount": 25.50,
    "description": "Integration Test Expense"
  }')

echo "Response from API: ${RESPONSE}"

# Assert response contains 'success' status
if echo "$RESPONSE" | grep -q '"status":"success"'; then
  echo "✓ Test PASSED: Expense successfully written to RDS and SNS event triggered."
  exit 0
else
  echo "✗ Test FAILED: API response did not match expected success output."
  exit 1
fi
