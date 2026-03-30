#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 03: Enforce IMDSv2 on All EC2 Instances
# Sets HttpTokens=required to prevent SSRF credential theft.
# No dependencies — can run independently.
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env 2>/dev/null || true

echo "============================================================"
echo " Enforcing IMDSv2 on All LinkedEye EC2 Instances"
echo "============================================================"

# ─── FIND ALL LINKEDEYE EC2s ───────────────────────────────
echo "[1/2] Discovering LinkedEye EC2 instances"

INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=LinkedEye" \
    "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text)

if [ -z "${INSTANCE_IDS}" ] || [ "${INSTANCE_IDS}" = "None" ]; then
  echo "    No LinkedEye EC2 instances found. Nothing to do."
  exit 0
fi

COUNT=$(echo "${INSTANCE_IDS}" | wc -w)
echo "    Found ${COUNT} instance(s)"

# ─── ENFORCE IMDSv2 ON EACH INSTANCE ──────────────────────
echo "[2/2] Setting HttpTokens=required on each instance"

for INSTANCE_ID in ${INSTANCE_IDS}; do
  INSTANCE_NAME=$(aws ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].Tags[?Key==`Name`].Value' \
    --output text 2>/dev/null || echo "unknown")

  # Check current IMDS settings
  CURRENT_TOKENS=$(aws ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' \
    --output text)

  if [ "${CURRENT_TOKENS}" = "required" ]; then
    echo "    ${INSTANCE_ID} (${INSTANCE_NAME}): already IMDSv2 — skipped"
    continue
  fi

  aws ec2 modify-instance-metadata-options \
    --instance-id "${INSTANCE_ID}" \
    --http-tokens required \
    --http-put-response-hop-limit 2 \
    --http-endpoint enabled

  echo "    ${INSTANCE_ID} (${INSTANCE_NAME}): IMDSv2 enforced"
done

echo ""
echo "[DONE] IMDSv2 enforced on all LinkedEye EC2 instances"
echo "  HttpTokens=required, HopLimit=2"
echo "  IMDSv1 requests will now be rejected (prevents SSRF credential theft)"
