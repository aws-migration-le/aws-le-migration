#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 07: Enable VPC Flow Logs
# Creates CloudWatch log group + IAM role, enables VPC Flow
# Logs for ALL traffic with 90-day retention.
# No dependencies — can run independently.
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Enabling VPC Flow Logs"
echo " VPC: ${VPC_ID}"
echo "============================================================"

FLOW_LOG_GROUP="/aws/vpc/flowlogs/${PROJECT}"
FLOW_LOG_ROLE="${PROJECT}-vpc-flow-log-role"

# ─── 1. CREATE CLOUDWATCH LOG GROUP ───────────────────────
echo "[1/3] Creating CloudWatch log group"

aws logs create-log-group \
  --log-group-name "${FLOW_LOG_GROUP}" \
  --tags Project="${TAG_PROJECT}",Environment="${TAG_ENV}" \
  2>/dev/null || echo "    Log group already exists"

aws logs put-retention-policy \
  --log-group-name "${FLOW_LOG_GROUP}" \
  --retention-in-days 90

echo "    Log group: ${FLOW_LOG_GROUP} (90-day retention)"

# ─── 2. CREATE IAM ROLE FOR FLOW LOGS ─────────────────────
echo "[2/3] Creating IAM role for VPC Flow Logs"

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "vpc-flow-logs.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

FLOW_LOG_ROLE_ARN=$(aws iam create-role \
  --role-name "${FLOW_LOG_ROLE}" \
  --assume-role-policy-document "${TRUST_POLICY}" \
  --tags Key=Project,Value="${TAG_PROJECT}" Key=Environment,Value="${TAG_ENV}" \
  --query 'Role.Arn' --output text 2>/dev/null || \
  aws iam get-role --role-name "${FLOW_LOG_ROLE}" --query 'Role.Arn' --output text)

aws iam put-role-policy \
  --role-name "${FLOW_LOG_ROLE}" \
  --policy-name "${PROJECT}-vpc-flow-log-policy" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ],
      "Resource": "*"
    }]
  }'

echo "    IAM Role: ${FLOW_LOG_ROLE_ARN}"

# Wait for IAM propagation
echo "    Waiting 10s for IAM propagation..."
sleep 10

# ─── 3. ENABLE VPC FLOW LOGS ──────────────────────────────
echo "[3/3] Enabling VPC Flow Logs (ALL traffic)"

# Check if flow logs already exist
EXISTING=$(aws ec2 describe-flow-logs \
  --filter "Name=resource-id,Values=${VPC_ID}" \
  --query 'FlowLogs[0].FlowLogId' --output text 2>/dev/null || echo "None")

if [ "${EXISTING}" != "None" ] && [ -n "${EXISTING}" ]; then
  echo "    Flow logs already enabled: ${EXISTING}"
else
  FLOW_LOG_ID=$(aws ec2 create-flow-logs \
    --resource-type VPC \
    --resource-ids "${VPC_ID}" \
    --traffic-type ALL \
    --log-destination-type cloud-watch-logs \
    --log-group-name "${FLOW_LOG_GROUP}" \
    --deliver-logs-permission-arn "${FLOW_LOG_ROLE_ARN}" \
    --tag-specifications "ResourceType=vpc-flow-log,Tags=[
      {Key=Name,Value=${PROJECT}-vpc-flow-logs},
      {Key=Project,Value=${TAG_PROJECT}},
      {Key=Environment,Value=${TAG_ENV}}
    ]" \
    --query 'FlowLogIds[0]' --output text)

  echo "    Flow Log ID: ${FLOW_LOG_ID}"
fi

# ─── PERSIST ────────────────────────────────────────────────
cat >> /tmp/le-network-ids.env <<EOF
export FLOW_LOG_GROUP="${FLOW_LOG_GROUP}"
export FLOW_LOG_ROLE_ARN="${FLOW_LOG_ROLE_ARN}"
EOF

echo ""
echo "[DONE] VPC Flow Logs enabled"
echo "  VPC:        ${VPC_ID}"
echo "  Log Group:  ${FLOW_LOG_GROUP}"
echo "  Traffic:    ALL (accept + reject)"
echo "  Retention:  90 days"
