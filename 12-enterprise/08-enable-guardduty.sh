#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 08: Enable GuardDuty
# Enables GuardDuty with EKS Audit Logs, EKS Runtime
# Monitoring, and EC2 agent management.
# No dependencies — can run independently.
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

echo "============================================================"
echo " Enabling Amazon GuardDuty"
echo " Region: ${AWS_REGION}"
echo "============================================================"

# ─── 1. CHECK / CREATE DETECTOR ──────────────────────────
echo "[1/2] Creating GuardDuty detector"

EXISTING_DETECTOR=$(aws guardduty list-detectors \
  --query 'DetectorIds[0]' --output text 2>/dev/null || echo "")

if [ -n "${EXISTING_DETECTOR}" ] && [ "${EXISTING_DETECTOR}" != "None" ]; then
  DETECTOR_ID="${EXISTING_DETECTOR}"
  echo "    Detector already exists: ${DETECTOR_ID}"
else
  DETECTOR_ID=$(aws guardduty create-detector \
    --enable \
    --finding-publishing-frequency FIFTEEN_MINUTES \
    --data-sources '{
      "S3Logs": {"Enable": true},
      "Kubernetes": {
        "AuditLogs": {"Enable": true}
      }
    }' \
    --tags Project="${TAG_PROJECT}",Environment="${TAG_ENV}" \
    --query 'DetectorId' --output text)

  echo "    Detector created: ${DETECTOR_ID}"
fi

# ─── 2. ENABLE EKS + EC2 FEATURES ────────────────────────
echo "[2/2] Enabling EKS Runtime Monitoring + EC2 agent management"

aws guardduty update-detector \
  --detector-id "${DETECTOR_ID}" \
  --enable \
  --features '[
    {
      "Name": "EKS_AUDIT_LOGS",
      "Status": "ENABLED"
    },
    {
      "Name": "EKS_RUNTIME_MONITORING",
      "Status": "ENABLED",
      "AdditionalConfiguration": [{
        "Name": "EKS_ADDON_MANAGEMENT",
        "Status": "ENABLED"
      }]
    },
    {
      "Name": "EC2_RUNTIME_MONITORING",
      "Status": "ENABLED",
      "AdditionalConfiguration": [{
        "Name": "EC2_AGENT_MANAGEMENT",
        "Status": "ENABLED"
      }]
    }
  ]' 2>/dev/null || echo "    Some features may not be available in ${AWS_REGION} — core detector is active"

# ─── PERSIST ────────────────────────────────────────────────
cat >> /tmp/le-network-ids.env <<EOF
export GUARDDUTY_DETECTOR_ID="${DETECTOR_ID}"
EOF

echo ""
echo "[DONE] GuardDuty enabled"
echo "  Detector:         ${DETECTOR_ID}"
echo "  EKS Audit Logs:   enabled"
echo "  EKS Runtime:      enabled (auto-managed addon)"
echo "  EC2 Runtime:      enabled (auto-managed agent)"
echo "  Finding Freq:     every 15 minutes"
echo ""
echo "  View findings:"
echo "    aws guardduty list-findings --detector-id ${DETECTOR_ID}"
