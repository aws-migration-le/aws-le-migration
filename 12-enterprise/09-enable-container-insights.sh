#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 09: Enable Container Insights
# Creates IRSA role and installs amazon-cloudwatch-observability
# EKS addon for Container Insights metrics + logs.
# No dependencies — can run independently.
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Enabling Container Insights via EKS Addon"
echo " Cluster: ${EKS_CLUSTER_NAME}"
echo "============================================================"

CI_ROLE_NAME="${PROJECT}-container-insights-role"

# ─── 1. GET OIDC PROVIDER ─────────────────────────────────
echo "[1/3] Retrieving OIDC provider for IRSA"

OIDC_URL=$(aws eks describe-cluster \
  --name "${EKS_CLUSTER_NAME}" \
  --query 'cluster.identity.oidc.issuer' --output text)

OIDC_ID=$(echo "${OIDC_URL}" | sed 's|https://||')

echo "    OIDC: ${OIDC_ID}"

# ─── 2. CREATE IRSA ROLE ──────────────────────────────────
echo "[2/3] Creating IRSA role for Container Insights"

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ID}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_ID}:aud": "sts.amazonaws.com",
        "${OIDC_ID}:sub": "system:serviceaccount:amazon-cloudwatch:cloudwatch-agent"
      }
    }
  }]
}
EOF
)

CI_ROLE_ARN=$(aws iam create-role \
  --role-name "${CI_ROLE_NAME}" \
  --assume-role-policy-document "${TRUST_POLICY}" \
  --tags Key=Project,Value="${TAG_PROJECT}" Key=Environment,Value="${TAG_ENV}" \
  --query 'Role.Arn' --output text 2>/dev/null || \
  aws iam get-role --role-name "${CI_ROLE_NAME}" --query 'Role.Arn' --output text)

aws iam attach-role-policy \
  --role-name "${CI_ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"

aws iam attach-role-policy \
  --role-name "${CI_ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"

echo "    Role: ${CI_ROLE_ARN}"

# ─── 3. INSTALL EKS ADDON ─────────────────────────────────
echo "[3/3] Installing amazon-cloudwatch-observability addon"

ADDON_STATUS=$(aws eks describe-addon \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --addon-name amazon-cloudwatch-observability \
  --query 'addon.status' --output text 2>/dev/null || echo "NOT_INSTALLED")

if [ "${ADDON_STATUS}" = "ACTIVE" ]; then
  echo "    Addon already active — skipping"
else
  aws eks create-addon \
    --cluster-name "${EKS_CLUSTER_NAME}" \
    --addon-name amazon-cloudwatch-observability \
    --service-account-role-arn "${CI_ROLE_ARN}" \
    --resolve-conflicts OVERWRITE

  echo "    Addon installation initiated — waiting for ACTIVE status..."

  aws eks wait addon-active \
    --cluster-name "${EKS_CLUSTER_NAME}" \
    --addon-name amazon-cloudwatch-observability \
    2>/dev/null || echo "    Addon may still be provisioning (check with: aws eks describe-addon)"
fi

echo ""
echo "[DONE] Container Insights enabled"
echo "  Cluster:  ${EKS_CLUSTER_NAME}"
echo "  Addon:    amazon-cloudwatch-observability"
echo "  Role:     ${CI_ROLE_ARN}"
echo ""
echo "  View metrics in CloudWatch > Container Insights"
