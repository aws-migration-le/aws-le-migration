#!/usr/bin/env bash
# ============================================================
# PHASE 6 — STEP 1: Initialize Kubernetes Cluster on Master
# Run this ON THE MASTER NODE (via SSH)
# ssh -J ubuntu@<BASTION_IP> ubuntu@10.15.10.10 -i ~/.ssh/le-shared-k8s-key.pem
# Then: sudo bash /tmp/01-init-k8s-master.sh
# ============================================================
set -euo pipefail

K8S_MASTER_IP="10.15.10.10"
POD_CIDR="192.168.0.0/16"
SERVICE_CIDR="172.20.0.0/16"
CLUSTER_NAME="le-shared-k8s"

echo "============================================================"
echo " Kubernetes Master Initialization — kubeadm init"
echo " Master IP: ${K8S_MASTER_IP}"
echo "============================================================"

# ─── PRE-FLIGHT CHECKS ───────────────────────────────────────
echo "[K8S-1] Pre-flight checks"
kubeadm version
kubectl version --client
containerd --version

# ─── KUBEADM INIT ────────────────────────────────────────────
echo "[K8S-2] Running kubeadm init"
kubeadm init \
  --apiserver-advertise-address="${K8S_MASTER_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --service-cidr="${SERVICE_CIDR}" \
  --node-name="le-k8s-master" \
  --kubernetes-version="1.29.0" \
  2>&1 | tee /tmp/kubeadm-init.log

# ─── CONFIGURE kubectl ───────────────────────────────────────
echo "[K8S-3] Configuring kubectl for ubuntu user"
mkdir -p /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown ubuntu:ubuntu /home/ubuntu/.kube/config

# Also for root
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config

echo "[K8S-4] Verifying cluster"
kubectl get nodes
kubectl get pods -n kube-system

# ─── EXTRACT JOIN COMMAND ────────────────────────────────────
echo "[K8S-5] Generating worker join command"
kubeadm token create --print-join-command > /tmp/worker-join.sh
chmod +x /tmp/worker-join.sh
echo ""
echo "Worker join command saved to /tmp/worker-join.sh:"
cat /tmp/worker-join.sh

echo ""
echo "[K8S-6] Saving kubeconfig for remote access"
cat /home/ubuntu/.kube/config

echo ""
echo "============================================================"
echo " [DONE] K8s Master initialized"
echo " NEXT STEPS:"
echo "  1. Copy /tmp/worker-join.sh to each worker node"
echo "  2. Run 02-join-workers.sh on each worker"
echo "  3. Run 03-install-calico-cni.sh on master"
echo "  4. Copy /home/ubuntu/.kube/config to your local machine"
echo "============================================================"
