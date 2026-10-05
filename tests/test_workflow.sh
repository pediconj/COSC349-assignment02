#!/bin/bash
set -e

# Fetch frontend IP from terraform output or pass as arg
FRONTEND_IP=${1:-$(cd terraform && terraform output -raw frontend_public_ip)}

echo "=================================================="
echo " Starting Automated SureSplit Workflow Test"
echo " Target IP: http://${FRONTEND_IP}"
echo "=================================================="

# 1. Health Check
echo -n "[1/4] Testing API Health Endpoint... "
HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${FRONTEND_IP}/api/health")
if [ "$HEALTH_STATUS" -eq 200 ]; then
    echo "PASSED (HTTP 200)"
else
    echo "FAILED (HTTP ${HEALTH_STATUS})"
    exit 1
fi

# 2. Fetch Default Groups
echo -n "[2/4] Testing Group Listing... "
GROUPS_RESP=$(curl -s "http://${FRONTEND_IP}/api/groups")
if echo "$GROUPS_RESP" | grep -q "Apartment 4B"; then
    echo "PASSED (Found 'Apartment 4B')"
else
    echo "FAILED (Groups response invalid)"
    exit 1
fi

# 3. Create a Test Group
TEST_GROUP="Automated-Test-$(date +%s)"
echo -n "[3/4] Creating New Group '${TEST_GROUP}'... "
CREATE_RESP=$(curl -s -X POST "http://${FRONTEND_IP}/api/groups" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${TEST_GROUP}\", \"members\": \"Alice, Bob, Charlie\"}")
if echo "$CREATE_RESP" | grep -q "success"; then
    echo "PASSED"
else
    echo "FAILED (${CREATE_RESP})"
    exit 1
fi

# 4. Add Expense & Verify Balances
echo -n "[4/4] Adding Expense to '${TEST_GROUP}'... "
EXPENSE_RESP=$(curl -s -X POST "http://${FRONTEND_IP}/api/expenses" \
  -H "Content-Type: application/json" \
  -d "{\"group_name\": \"${TEST_GROUP}\", \"description\": \"Dinner\", \"amount\": 90.00, \"paid_by\": \"Alice\"}")

if echo "$EXPENSE_RESP" | grep -q "success"; then
    echo "PASSED"
else
    echo "FAILED (${EXPENSE_RESP})"
    exit 1
fi

echo "=================================================="
echo " ALL AUTOMATED WORKFLOW TESTS PASSED SUCCESSFULLY "
echo "=================================================="
