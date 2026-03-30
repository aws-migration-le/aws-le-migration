#!/usr/bin/env bash
# ============================================================
# PHASE 5 — STEP 2: Add ALB Rules for 15 Client FQDNs
# Adds host-based routing rules for all client sites.
# All client FQDNs (fs-le-*.finspot.in) route to EC2-B:80 (ITSM).
#
# Prerequisites:
#   - ALB already created (01-create-alb-for-tools.sh)
#   - HTTPS listener on port 443 exists
#   - *.finspot.in wildcard cert covers all subdomains
#
# Usage:
#   ./02-add-client-alb-rules.sh           # Add all 15 client rules
#   ./02-add-client-alb-rules.sh list      # List existing rules
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

ACTION="${1:-create}"

echo "============================================================"
echo " Adding Client FQDN Rules to ALB"
echo " ALB: ${ALB_TOOLS_ARN:-${ALB_ARN}}"
echo "============================================================"

# Use the tools ALB (created by 01-create-alb-for-tools.sh)
ACTIVE_ALB_ARN="${ALB_TOOLS_ARN:-${ALB_ARN}}"

# ─── FIND HTTPS LISTENER ─────────────────────────────────────
echo "[ALB-CLIENT-1] Finding HTTPS listener on port 443"
LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "${ACTIVE_ALB_ARN}" \
  --query "Listeners[?Port==\`443\`].ListenerArn" \
  --output text)

if [ -z "${LISTENER_ARN}" ] || [ "${LISTENER_ARN}" = "None" ]; then
  echo "ERROR: No HTTPS listener found on ALB. Run 01-create-alb-for-tools.sh first."
  exit 1
fi
echo "    Listener: ${LISTENER_ARN}"

# ─── LIST MODE ────────────────────────────────────────────────
if [ "${ACTION}" = "list" ]; then
  echo ""
  echo "  Existing ALB rules:"
  aws elbv2 describe-rules --listener-arn "${LISTENER_ARN}" \
    --query 'Rules[*].[Priority,Conditions[0].Values[0],Actions[0].TargetGroupArn]' \
    --output table
  exit 0
fi

# ─── CLIENT FQDN LIST ────────────────────────────────────────
# All client FQDNs route to EC2-B:80 (ITSM instance)
CLIENT_FQDNS=(
  "fs-le-indmoney.finspot.in"
  "fs-le-neo.finspot.in"
  "fs-le-dx.finspot.in"
  "fs-le-ifsc.finspot.in"
  "fs-le-w2w.finspot.in"
  "fs-le-ftc.finspot.in"
  "fs-le-pl.finspot.in"
  "fs-le-isv1.finspot.in"
  "fs-le-isv2.finspot.in"
  "fs-le-isv3.finspot.in"
  "fs-le-isv4.finspot.in"
  "fs-le-isv5.finspot.in"
  "fs-le-mirae.finspot.in"
  "fs-le-smifs.finspot.in"
  "fs-le-lemonn.finspot.in"
)

# ─── GET EXISTING RULES TO FIND NEXT PRIORITY ────────────────
echo "[ALB-CLIENT-2] Checking existing rules"
EXISTING_PRIORITIES=$(aws elbv2 describe-rules \
  --listener-arn "${LISTENER_ARN}" \
  --query 'Rules[?Priority!=`default`].Priority' \
  --output text)

MAX_PRIORITY=0
for P in ${EXISTING_PRIORITIES}; do
  if [ "${P}" -gt "${MAX_PRIORITY}" ] 2>/dev/null; then
    MAX_PRIORITY="${P}"
  fi
done
echo "    Existing rules: $(echo "${EXISTING_PRIORITIES}" | wc -w | tr -d ' ')"
echo "    Max priority: ${MAX_PRIORITY}"

# Start new rules after existing ones
NEXT_PRIORITY=$((MAX_PRIORITY + 1))

# ─── CREATE SHARED TARGET GROUP FOR CLIENT ITSM ──────────────
echo "[ALB-CLIENT-3] Creating/finding target group for client ITSM (EC2-B:80)"

# Check if target group already exists
TG_CLIENT_ITSM=$(aws elbv2 describe-target-groups \
  --names "${PROJECT}-tg-client-itsm" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null || echo "")

if [ -z "${TG_CLIENT_ITSM}" ] || [ "${TG_CLIENT_ITSM}" = "None" ]; then
  TG_CLIENT_ITSM=$(aws elbv2 create-target-group \
    --name "${PROJECT}-tg-client-itsm" \
    --protocol HTTP --port 80 \
    --vpc-id "${VPC_ID}" \
    --target-type instance \
    --health-check-path "/" \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --tags Key=Project,Value=${TAG_PROJECT} Key=Purpose,Value=client-itsm \
    --query 'TargetGroups[0].TargetGroupArn' --output text)

  aws elbv2 register-targets \
    --target-group-arn "${TG_CLIENT_ITSM}" \
    --targets "Id=${MGMT_EC2_ID},Port=80"
  echo "    Created TG: ${PROJECT}-tg-client-itsm → EC2-B:80"
else
  echo "    TG already exists: ${PROJECT}-tg-client-itsm"
fi

# ─── CREATE ALB RULES FOR EACH CLIENT FQDN ───────────────────
echo ""
echo "[ALB-CLIENT-4] Adding host-based routing rules"
RULES_CREATED=0
RULES_SKIPPED=0

for FQDN in "${CLIENT_FQDNS[@]}"; do
  # Check if rule already exists for this host
  EXISTING=$(aws elbv2 describe-rules \
    --listener-arn "${LISTENER_ARN}" \
    --query "Rules[?Conditions[?Values[?contains(@, '${FQDN}')]]].[Priority]" \
    --output text 2>/dev/null | head -1)

  if [ -n "${EXISTING}" ] && [ "${EXISTING}" != "None" ] && [ "${EXISTING}" != "" ]; then
    echo "    [SKIP] ${FQDN} (rule exists at priority ${EXISTING})"
    ((RULES_SKIPPED++))
    continue
  fi

  aws elbv2 create-rule \
    --listener-arn "${LISTENER_ARN}" \
    --priority "${NEXT_PRIORITY}" \
    --conditions "Field=host-header,Values=[${FQDN}]" \
    --actions "Type=forward,TargetGroupArn=${TG_CLIENT_ITSM}"

  echo "    [ADD] Priority ${NEXT_PRIORITY}: ${FQDN} → EC2-B:80"
  ((NEXT_PRIORITY++))
  ((RULES_CREATED++))
done

# ─── PERSIST ──────────────────────────────────────────────────
cat >> /tmp/le-network-ids.env <<EOF
export TG_CLIENT_ITSM="${TG_CLIENT_ITSM}"
EOF

# ─── VERIFY ───────────────────────────────────────────────────
echo ""
echo "[ALB-CLIENT-5] Verification"
TOTAL_RULES=$(aws elbv2 describe-rules \
  --listener-arn "${LISTENER_ARN}" \
  --query 'Rules[?Priority!=`default`]' \
  --output json | jq length)
echo "    Total ALB rules: ${TOTAL_RULES} (6 tools + ${RULES_CREATED} clients)"

echo ""
echo "============================================================"
echo "[DONE] Client ALB rules configured"
echo ""
echo "  Rules created: ${RULES_CREATED}"
echo "  Rules skipped: ${RULES_SKIPPED} (already existed)"
echo "  Total rules:   ${TOTAL_RULES}"
echo ""
echo "  All client FQDNs route to EC2-B:80 (ITSM)"
echo "  Wildcard cert *.finspot.in covers all subdomains"
echo ""
echo "  DNS REQUIRED (GoDaddy):"
echo "  ───────────────────────"
for FQDN in "${CLIENT_FQDNS[@]}"; do
  echo "    CNAME  ${FQDN}  →  ${ALB_TOOLS_DNS:-${ALB_DNS}}"
done
echo ""
echo "  Or single wildcard CNAME:"
echo "    CNAME  *.finspot.in  →  ${ALB_TOOLS_DNS:-${ALB_DNS}}"
echo "============================================================"
