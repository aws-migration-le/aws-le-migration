#!/usr/bin/env bash
# ============================================================
# PHASE 4 — STEP 1: SSH Key Pair for EC2 Instances
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

KEY_FILE="${HOME}/.ssh/${KEY_PAIR_NAME}.pem"

echo "============================================================"
echo " SSH Key Pair: ${KEY_PAIR_NAME}"
echo "============================================================"

# Check if already exists
EXISTING=$(aws ec2 describe-key-pairs \
  --key-names "${KEY_PAIR_NAME}" 2>/dev/null \
  --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || echo "")

if [[ "${EXISTING}" == "${KEY_PAIR_NAME}" ]]; then
  echo "  Key pair already exists. Skipping creation."
  echo "  Make sure ${KEY_FILE} exists locally."
else
  echo "[KP-1] Creating key pair and saving to ${KEY_FILE}"
  aws ec2 create-key-pair \
    --key-name "${KEY_PAIR_NAME}" \
    --key-type rsa \
    --key-format pem \
    --tag-specifications "ResourceType=key-pair,Tags=[
      {Key=Name,Value=${KEY_PAIR_NAME}},{Key=Project,Value=${TAG_PROJECT}}
    ]" \
    --query 'KeyMaterial' --output text > "${KEY_FILE}"

  chmod 400 "${KEY_FILE}"
  echo "  Key saved: ${KEY_FILE} (chmod 400)"
fi

cat >> /tmp/le-network-ids.env <<EOF
export KEY_PAIR_NAME="${KEY_PAIR_NAME}"
export KEY_FILE="${KEY_FILE}"
EOF

echo "[DONE] Key pair ready: ${KEY_PAIR_NAME}"
