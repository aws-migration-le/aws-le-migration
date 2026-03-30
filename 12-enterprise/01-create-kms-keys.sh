#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 01: Create KMS Customer-Managed Keys
# Creates 3 CMKs: EKS secrets encryption, Vault auto-unseal,
# EBS volume encryption. Enables annual key rotation.
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env 2>/dev/null || true

echo "============================================================"
echo " Creating KMS Customer-Managed Keys (3 keys)"
echo "============================================================"

# ─── 1. EKS SECRETS ENCRYPTION KEY ─────────────────────────
echo "[1/3] Creating KMS key for EKS secrets envelope encryption"

KMS_EKS_KEY_ID=$(aws kms create-key \
  --description "LinkedEye EKS secrets-at-rest envelope encryption" \
  --key-usage ENCRYPT_DECRYPT \
  --origin AWS_KMS \
  --tags \
    TagKey=Name,TagValue=${PROJECT}-kms-eks \
    TagKey=Project,TagValue=${TAG_PROJECT} \
    TagKey=Environment,TagValue=${TAG_ENV} \
    TagKey=Purpose,TagValue=eks-secrets-encryption \
  --query 'KeyMetadata.KeyId' --output text)

echo "    Key ID: ${KMS_EKS_KEY_ID}"

aws kms create-alias \
  --alias-name "alias/${KMS_EKS_ALIAS}" \
  --target-key-id "${KMS_EKS_KEY_ID}"

aws kms enable-key-rotation --key-id "${KMS_EKS_KEY_ID}"
echo "    Alias:  alias/${KMS_EKS_ALIAS}"
echo "    Rotation: enabled (annual)"

KMS_EKS_KEY_ARN=$(aws kms describe-key \
  --key-id "${KMS_EKS_KEY_ID}" \
  --query 'KeyMetadata.Arn' --output text)

# ─── 2. VAULT AUTO-UNSEAL KEY ──────────────────────────────
echo ""
echo "[2/3] Creating KMS key for Vault auto-unseal"

KMS_VAULT_KEY_ID=$(aws kms create-key \
  --description "LinkedEye Vault auto-unseal (KMS seal)" \
  --key-usage ENCRYPT_DECRYPT \
  --origin AWS_KMS \
  --tags \
    TagKey=Name,TagValue=${PROJECT}-kms-vault \
    TagKey=Project,TagValue=${TAG_PROJECT} \
    TagKey=Environment,TagValue=${TAG_ENV} \
    TagKey=Purpose,TagValue=vault-auto-unseal \
  --query 'KeyMetadata.KeyId' --output text)

echo "    Key ID: ${KMS_VAULT_KEY_ID}"

aws kms create-alias \
  --alias-name "alias/${KMS_VAULT_ALIAS}" \
  --target-key-id "${KMS_VAULT_KEY_ID}"

aws kms enable-key-rotation --key-id "${KMS_VAULT_KEY_ID}"
echo "    Alias:  alias/${KMS_VAULT_ALIAS}"
echo "    Rotation: enabled (annual)"

KMS_VAULT_KEY_ARN=$(aws kms describe-key \
  --key-id "${KMS_VAULT_KEY_ID}" \
  --query 'KeyMetadata.Arn' --output text)

# ─── 3. EBS ENCRYPTION KEY ─────────────────────────────────
echo ""
echo "[3/3] Creating KMS key for EBS volume encryption"

KMS_EBS_KEY_ID=$(aws kms create-key \
  --description "LinkedEye EBS default volume encryption" \
  --key-usage ENCRYPT_DECRYPT \
  --origin AWS_KMS \
  --tags \
    TagKey=Name,TagValue=${PROJECT}-kms-ebs \
    TagKey=Project,TagValue=${TAG_PROJECT} \
    TagKey=Environment,TagValue=${TAG_ENV} \
    TagKey=Purpose,TagValue=ebs-encryption \
  --query 'KeyMetadata.KeyId' --output text)

echo "    Key ID: ${KMS_EBS_KEY_ID}"

aws kms create-alias \
  --alias-name "alias/${KMS_EBS_ALIAS}" \
  --target-key-id "${KMS_EBS_KEY_ID}"

aws kms enable-key-rotation --key-id "${KMS_EBS_KEY_ID}"
echo "    Alias:  alias/${KMS_EBS_ALIAS}"
echo "    Rotation: enabled (annual)"

KMS_EBS_KEY_ARN=$(aws kms describe-key \
  --key-id "${KMS_EBS_KEY_ID}" \
  --query 'KeyMetadata.Arn' --output text)

# ─── PERSIST ────────────────────────────────────────────────
cat >> /tmp/le-network-ids.env <<EOF
export KMS_EKS_KEY_ID="${KMS_EKS_KEY_ID}"
export KMS_EKS_KEY_ARN="${KMS_EKS_KEY_ARN}"
export KMS_VAULT_KEY_ID="${KMS_VAULT_KEY_ID}"
export KMS_VAULT_KEY_ARN="${KMS_VAULT_KEY_ARN}"
export KMS_EBS_KEY_ID="${KMS_EBS_KEY_ID}"
export KMS_EBS_KEY_ARN="${KMS_EBS_KEY_ARN}"
EOF

echo ""
echo "[DONE] 3 KMS Customer-Managed Keys created"
echo "  EKS Secrets: ${KMS_EKS_KEY_ARN}"
echo "  Vault Seal:  ${KMS_VAULT_KEY_ARN}"
echo "  EBS Default: ${KMS_EBS_KEY_ARN}"
echo ""
echo "  All keys have annual rotation enabled."
echo "  Next: Run 02-enable-eks-encryption.sh"
