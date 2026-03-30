#!/usr/bin/env bash
# ============================================================
# PHASE 1 — STEP 5: Tag Subnets for EKS Auto-Discovery
# Adds kubernetes.io/cluster tags so EKS + ALB Controller
# can discover subnets for load balancers and nodes.
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Tagging Subnets for EKS Cluster: ${EKS_CLUSTER_NAME}"
echo "============================================================"

# ─── PUBLIC SUBNETS — for external ALBs ─────────────────────
echo "[5.1] Tagging public subnets for EKS external load balancers"
for SUBNET_ID in "${PUB_SUBNET_AZ1}" "${PUB_SUBNET_AZ2}"; do
  aws ec2 create-tags --resources "${SUBNET_ID}" --tags \
    "Key=kubernetes.io/cluster/${EKS_CLUSTER_NAME},Value=shared" \
    "Key=kubernetes.io/role/elb,Value=1"
  echo "    Tagged: ${SUBNET_ID} (public, elb=1)"
done

# ─── PRIVATE SUBNETS — for internal ALBs + EKS nodes ────────
echo "[5.2] Tagging private subnets for EKS internal load balancers + nodes"
for SUBNET_ID in "${EKS_SUBNET_AZ1B}" "${EKS_SUBNET_AZ1C}"; do
  aws ec2 create-tags --resources "${SUBNET_ID}" --tags \
    "Key=kubernetes.io/cluster/${EKS_CLUSTER_NAME},Value=shared" \
    "Key=kubernetes.io/role/internal-elb,Value=1"
  echo "    Tagged: ${SUBNET_ID} (private, internal-elb=1)"
done

# ─── MANAGEMENT SUBNET — tag for cluster awareness ──────────
echo "[5.3] Tagging management subnet (AZ1a) for cluster awareness"
aws ec2 create-tags --resources "${PRIV_SUBNET_AZ1}" --tags \
  "Key=kubernetes.io/cluster/${EKS_CLUSTER_NAME},Value=shared"
echo "    Tagged: ${PRIV_SUBNET_AZ1} (mgmt, cluster awareness)"

echo ""
echo "[DONE] Subnet tagging complete for EKS: ${EKS_CLUSTER_NAME}"
echo "  Public  (elb=1):          ${PUB_SUBNET_AZ1}, ${PUB_SUBNET_AZ2}"
echo "  Private (internal-elb=1): ${EKS_SUBNET_AZ1B}, ${EKS_SUBNET_AZ1C}"
echo "  Mgmt    (cluster=shared): ${PRIV_SUBNET_AZ1}"
