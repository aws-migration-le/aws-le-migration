#!/usr/bin/env bash
# ============================================================
# PHASE 6 — STEP 6: Install EKS Add-ons
# For Hybrid Nodes: vpc-cni, coredns, kube-proxy
# NOTE: EBS CSI not needed — on-prem nodes use local storage
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Installing EKS Add-ons: ${EKS_CLUSTER_NAME}"
echo " (Hybrid Nodes mode — on-prem workers)"
echo "============================================================"

# ─── VPC CNI ────────────────────────────────────────────────
echo "[ADDON-1] Installing/updating VPC CNI"
aws eks create-addon \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --addon-name vpc-cni \
  --resolve-conflicts OVERWRITE \
  2>/dev/null || \
aws eks update-addon \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --addon-name vpc-cni \
  --resolve-conflicts OVERWRITE
echo "    vpc-cni: installed"

# ─── CoreDNS ────────────────────────────────────────────────
echo "[ADDON-2] Installing/updating CoreDNS"
aws eks create-addon \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --addon-name coredns \
  --resolve-conflicts OVERWRITE \
  2>/dev/null || \
aws eks update-addon \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --addon-name coredns \
  --resolve-conflicts OVERWRITE
echo "    coredns: installed"

# ─── kube-proxy ──────────────────────────────────────────────
echo "[ADDON-3] Installing/updating kube-proxy"
aws eks create-addon \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --addon-name kube-proxy \
  --resolve-conflicts OVERWRITE \
  2>/dev/null || \
aws eks update-addon \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --addon-name kube-proxy \
  --resolve-conflicts OVERWRITE
echo "    kube-proxy: installed"

# ─── WAIT FOR ADD-ONS ───────────────────────────────────────
echo ""
echo "[ADDON-4] Waiting for add-ons to become ACTIVE..."
for ADDON in vpc-cni coredns kube-proxy; do
  echo -n "    ${ADDON}: "
  aws eks wait addon-active \
    --cluster-name "${EKS_CLUSTER_NAME}" \
    --addon-name "${ADDON}" 2>/dev/null && echo "ACTIVE" || echo "PENDING"
done

echo ""
echo "[DONE] EKS add-ons installed"
echo "  vpc-cni, coredns, kube-proxy"
echo ""
echo "  NOTE: EBS CSI driver NOT installed — hybrid on-prem nodes"
echo "  use local storage or NFS. If needed later, install via:"
echo "    aws eks create-addon --cluster-name ${EKS_CLUSTER_NAME} --addon-name aws-ebs-csi-driver"
echo ""
echo "  NEXT: Run 06-kubernetes/07-install-alb-controller.sh"
