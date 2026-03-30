#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 02: Enable EKS Secrets-at-Rest Encryption
# Associates KMS CMK with EKS cluster for envelope encryption.
# Depends on: 01-create-kms-keys.sh (KMS_EKS_KEY_ARN)
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Enabling EKS Secrets-at-Rest Encryption"
echo " Cluster: ${EKS_CLUSTER_NAME}"
echo " KMS Key: ${KMS_EKS_KEY_ARN}"
echo "============================================================"

# ─── CHECK CURRENT ENCRYPTION STATUS ───────────────────────
echo "[1/3] Checking current encryption configuration"

EXISTING_ENC=$(aws eks describe-cluster \
  --name "${EKS_CLUSTER_NAME}" \
  --query 'cluster.encryptionConfig[0].provider.keyArn' \
  --output text 2>/dev/null || echo "None")

if [ "${EXISTING_ENC}" != "None" ]; then
  echo "    Encryption already configured with key: ${EXISTING_ENC}"
  echo "    Skipping association."
  exit 0
fi

# ─── ASSOCIATE KMS KEY WITH EKS ────────────────────────────
echo "[2/3] Associating KMS key with EKS cluster (secrets encryption)"

aws eks associate-encryption-config \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --encryption-config '[{
    "resources": ["secrets"],
    "provider": {
      "keyArn": "'"${KMS_EKS_KEY_ARN}"'"
    }
  }]'

echo "    Association initiated — this takes 10-15 minutes..."

# ─── WAIT FOR ASSOCIATION ───────────────────────────────────
echo "[3/3] Waiting for encryption association to complete"

while true; do
  STATUS=$(aws eks describe-update \
    --name "${EKS_CLUSTER_NAME}" \
    --update-id "$(aws eks list-updates \
      --name "${EKS_CLUSTER_NAME}" \
      --query 'updateIds[0]' --output text)" \
    --query 'update.status' --output text 2>/dev/null || echo "InProgress")

  if [ "${STATUS}" = "Successful" ]; then
    echo "    Encryption association successful"
    break
  elif [ "${STATUS}" = "Failed" ]; then
    echo "    [ERROR] Encryption association failed!"
    aws eks describe-update \
      --name "${EKS_CLUSTER_NAME}" \
      --update-id "$(aws eks list-updates \
        --name "${EKS_CLUSTER_NAME}" \
        --query 'updateIds[0]' --output text)"
    exit 1
  fi

  echo "    Status: ${STATUS} — waiting 30s..."
  sleep 30
done

# ─── RE-ENCRYPT EXISTING SECRETS ───────────────────────────
echo ""
echo "[INFO] To re-encrypt existing secrets with the new KMS key, run:"
echo "  kubectl get secrets --all-namespaces -o json | kubectl replace -f -"

echo ""
echo "[DONE] EKS secrets-at-rest encryption enabled"
echo "  Cluster: ${EKS_CLUSTER_NAME}"
echo "  KMS Key: ${KMS_EKS_KEY_ARN}"
echo "  All new secrets will be encrypted with this key."
