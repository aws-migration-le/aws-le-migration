#!/usr/bin/env bash
# ============================================================
# PHASE 6 — STEP 2: Join Worker Nodes to Cluster
# Run FROM YOUR LOCAL MACHINE (uses SSH proxy through bastion)
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

BASTION_IP="${BASTION_PUBLIC_IP}"
KEY="${KEY_FILE}"

echo "============================================================"
echo " Joining Worker Nodes to K8s Cluster"
echo "============================================================"

# ─── GET JOIN COMMAND FROM MASTER ────────────────────────────
echo "[JOIN-1] Fetching worker join command from master"
JOIN_CMD=$(ssh -o StrictHostKeyChecking=no \
  -o ProxyJump="ubuntu@${BASTION_IP}" \
  -i "${KEY}" \
  ubuntu@${K8S_MASTER_PRIVATE_IP} \
  "cat /tmp/worker-join.sh")

echo "    Join command: ${JOIN_CMD}"

# ─── JOIN WORKER 1 ───────────────────────────────────────────
echo "[JOIN-2] Joining Worker 1 (${WORKER1_IP})"
ssh -o StrictHostKeyChecking=no \
  -o ProxyJump="ubuntu@${BASTION_IP}" \
  -i "${KEY}" \
  ubuntu@${WORKER1_IP} \
  "sudo ${JOIN_CMD} --node-name le-k8s-worker-1"

# ─── VERIFY ──────────────────────────────────────────────────
echo "[JOIN-3] Verifying nodes joined (master + 1 worker)"
sleep 20
ssh -o StrictHostKeyChecking=no \
  -o ProxyJump="ubuntu@${BASTION_IP}" \
  -i "${KEY}" \
  ubuntu@${K8S_MASTER_PRIVATE_IP} \
  "kubectl get nodes -o wide"

echo ""
echo "[DONE] Cluster ready — 1 master + 1 worker"
echo "  Add more workers later: re-run join command on new EC2 instances"
