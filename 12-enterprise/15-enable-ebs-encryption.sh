#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 15: Enable EBS Encryption by Default
# Enables default EBS encryption for the region with custom
# KMS key. All new EBS volumes will be encrypted automatically.
# Depends on: 01-create-kms-keys.sh (KMS_EBS_KEY_ARN)
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Enabling EBS Encryption by Default"
echo " Region: ${AWS_REGION}"
echo " KMS Key: ${KMS_EBS_KEY_ARN}"
echo "============================================================"

# ─── 1. SET DEFAULT KMS KEY FOR EBS ──────────────────────
echo "[1/2] Setting custom KMS key as default for EBS encryption"

aws ec2 modify-ebs-default-kms-key-id \
  --kms-key-id "${KMS_EBS_KEY_ARN}"

echo "    Default KMS key set: ${KMS_EBS_KEY_ARN}"

# ─── 2. ENABLE EBS ENCRYPTION BY DEFAULT ─────────────────
echo "[2/2] Enabling EBS encryption by default for ${AWS_REGION}"

aws ec2 enable-ebs-encryption-by-default

CURRENT_STATE=$(aws ec2 get-ebs-encryption-by-default \
  --query 'EbsEncryptionByDefault' --output text)

echo "    EBS encryption by default: ${CURRENT_STATE}"

echo ""
echo "[DONE] EBS encryption enabled by default"
echo "  Region:     ${AWS_REGION}"
echo "  KMS Key:    ${KMS_EBS_KEY_ARN}"
echo "  All new EBS volumes will be encrypted automatically."
echo ""
echo "  EXISTING VOLUMES:"
echo "  Unencrypted volumes must be migrated manually:"
echo "    1. Create a snapshot of the unencrypted volume"
echo "    2. Copy the snapshot with encryption enabled:"
echo "       aws ec2 copy-snapshot --source-snapshot-id snap-xxx \\"
echo "         --encrypted --kms-key-id ${KMS_EBS_KEY_ARN} \\"
echo "         --source-region ${AWS_REGION}"
echo "    3. Create a new volume from the encrypted snapshot"
echo "    4. Swap the volume on the instance (stop instance first)"
