#!/usr/bin/env bash
# ============================================================
# PHASE H — Cleanup: Terminate Old kubeadm EC2 Instances
# Removes: kubeadm master (i-0254e6bd512f67dd9)
#          kubeadm worker (i-0e0662a64aa8cc8e6)
# WARNING: This is DESTRUCTIVE and cannot be undone!
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

echo "============================================================"
echo " CLEANUP: Terminate Old kubeadm EC2 Instances"
echo "============================================================"

OLD_MASTER_ID="i-0254e6bd512f67dd9"
OLD_WORKER_ID="i-0e0662a64aa8cc8e6"

# ─── PRE-FLIGHT CHECKS ─────────────────────────────────────
echo "[CLEANUP-1] Verifying new infrastructure is healthy before cleanup"

# Check new EC2s are running
echo "  Checking new management EC2s..."
for ROLE in jenkins mgmt-tools itsm; do
  STATE=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${PROJECT}-${ROLE}-ec2" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)
  if [ "${STATE}" != "running" ]; then
    echo "  [ABORT] ${PROJECT}-${ROLE}-ec2 is NOT running (state: ${STATE})"
    echo "  Fix new infrastructure before deleting old instances!"
    exit 1
  fi
  echo "    ${PROJECT}-${ROLE}-ec2: running"
done

# Check EKS cluster
echo "  Checking EKS cluster..."
EKS_STATUS=$(aws eks describe-cluster --name "${EKS_CLUSTER_NAME}" \
  --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")
if [ "${EKS_STATUS}" != "ACTIVE" ]; then
  echo "  [ABORT] EKS cluster ${EKS_CLUSTER_NAME} is NOT ACTIVE (status: ${EKS_STATUS})"
  exit 1
fi
echo "    EKS cluster: ACTIVE"

# ─── CONFIRM ────────────────────────────────────────────────
echo ""
echo "  About to terminate:"
echo "    ${OLD_MASTER_ID} (kubeadm master, m5.2xlarge)"
echo "    ${OLD_WORKER_ID} (kubeadm worker, m5.4xlarge)"
echo ""
read -p "  Type 'DELETE' to confirm: " CONFIRM
if [ "${CONFIRM}" != "DELETE" ]; then
  echo "  Aborted."
  exit 0
fi

# ─── TERMINATE ──────────────────────────────────────────────
echo ""
echo "[CLEANUP-2] Terminating old kubeadm instances"

aws ec2 terminate-instances --instance-ids "${OLD_MASTER_ID}" "${OLD_WORKER_ID}"
echo "    Termination initiated"

echo "[CLEANUP-3] Waiting for instances to terminate..."
aws ec2 wait instance-terminated --instance-ids "${OLD_MASTER_ID}" "${OLD_WORKER_ID}"
echo "    Both instances terminated"

# ─── CLEANUP OLD SECURITY GROUPS ────────────────────────────
echo "[CLEANUP-4] Checking if old SGs can be deleted"
for SG_NAME in "${PROJECT}-k8s-master-sg" "${PROJECT}-k8s-worker-sg"; do
  SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
  if [ -n "${SG_ID}" ] && [ "${SG_ID}" != "None" ]; then
    # Check if SG is still in use
    ENI_COUNT=$(aws ec2 describe-network-interfaces \
      --filters "Name=group-id,Values=${SG_ID}" \
      --query 'length(NetworkInterfaces)' --output text)
    if [ "${ENI_COUNT}" = "0" ]; then
      aws ec2 delete-security-group --group-id "${SG_ID}" 2>/dev/null && \
        echo "    Deleted SG: ${SG_NAME} (${SG_ID})" || \
        echo "    Could not delete SG: ${SG_NAME} (${SG_ID}) — may have dependencies"
    else
      echo "    Skipping SG: ${SG_NAME} (${SG_ID}) — still has ${ENI_COUNT} ENI(s)"
    fi
  fi
done

# ─── RELEASE UNUSED EIPs ────────────────────────────────────
echo "[CLEANUP-5] Checking for unassociated Elastic IPs"
UNASSOCIATED_EIPS=$(aws ec2 describe-addresses \
  --filters "Name=tag:Project,Values=${TAG_PROJECT}" \
  --query 'Addresses[?AssociationId==null].AllocationId' --output text)
for EIP_ID in ${UNASSOCIATED_EIPS}; do
  aws ec2 release-address --allocation-id "${EIP_ID}" 2>/dev/null && \
    echo "    Released EIP: ${EIP_ID}" || \
    echo "    Could not release EIP: ${EIP_ID}"
done

echo ""
echo "[DONE] Cleanup complete"
echo "  Terminated: ${OLD_MASTER_ID}, ${OLD_WORKER_ID}"
echo "  Estimated monthly savings: ~$700 (m5.2xlarge + m5.4xlarge)"
