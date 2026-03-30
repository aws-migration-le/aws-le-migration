#!/usr/bin/env bash
# ============================================================
# PHASE 6 — STEP 8: Configure EKS Access
# Namespaces, StorageClass (local), aws-auth for hybrid nodes
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Configuring EKS Access & Resources (Hybrid Nodes)"
echo "============================================================"

# ─── NAMESPACES ─────────────────────────────────────────────
echo "[ACCESS-1] Creating namespaces"
for NS in le-monitoring le-workloads; do
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "${NS}" project=linkedeye environment=prod --overwrite
  echo "    Namespace: ${NS}"
done

# ─── LOCAL STORAGE CLASS (for on-prem hybrid nodes) ─────────
echo "[ACCESS-2] Creating local-path StorageClass (default for hybrid nodes)"
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
echo "    StorageClass: local-path (default)"

# ─── NETWORK POLICY — client isolation ──────────────────────
echo "[ACCESS-3] Creating default network policy for client isolation"
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: client-isolation
  namespace: le-workloads
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              project: linkedeye
EOF
echo "    NetworkPolicy: client-isolation (le-workloads)"

# ─── VERIFY ─────────────────────────────────────────────────
echo ""
echo "[ACCESS-4] Verification"
echo "  Namespaces:"
kubectl get ns | grep -E "le-|kube-"
echo ""
echo "  StorageClasses:"
kubectl get sc
echo ""
echo "  aws-auth ConfigMap:"
kubectl get configmap aws-auth -n kube-system -o yaml 2>/dev/null | head -30

echo ""
echo "[DONE] EKS access configured for Hybrid Nodes"
echo "  Namespaces:    le-monitoring, le-workloads"
echo "  StorageClass:  local-path (for on-prem hybrid nodes)"
echo "  Isolation:     NetworkPolicy for client workload separation"
echo ""
echo "  VERIFY from EC2-B:"
echo "    aws eks update-kubeconfig --name ${EKS_CLUSTER_NAME}"
echo "    kubectl get ns"
