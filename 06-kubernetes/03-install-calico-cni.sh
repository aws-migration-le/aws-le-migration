#!/usr/bin/env bash
# ============================================================
# PHASE 6 — STEP 3: Install Calico CNI + K8s Namespaces
# Run ON MASTER NODE or locally with kubeconfig
# ============================================================
set -euo pipefail

echo "============================================================"
echo " Installing Calico CNI (Pod Network)"
echo "============================================================"

# ─── CALICO ──────────────────────────────────────────────────
echo "[CNI-1] Installing Calico operator"
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml

echo "[CNI-2] Applying Calico custom resources (pod CIDR: 192.168.0.0/16)"
cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 192.168.0.0/16
      encapsulation: IPIP
      natOutgoing: Enabled
      nodeSelector: all()
EOF

echo "[CNI-3] Waiting for Calico to be ready..."
kubectl wait --for=condition=Available deployment/calico-kube-controllers \
  -n calico-system --timeout=300s || true
kubectl get pods -n calico-system

# ─── NAMESPACES ──────────────────────────────────────────────
echo "[NS-1] Creating LinkedEye namespaces"
for NS in le-cicd le-security le-monitoring le-logging le-automation le-data le-shared; do
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "${NS}" project=linkedeye environment=prod --overwrite
  echo "    Namespace: ${NS}"
done

# ─── STORAGE CLASS ───────────────────────────────────────────
echo "[SC-1] Creating gp3 StorageClass (default)"
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
EOF

echo ""
echo "[DONE] CNI, namespaces, and storage class ready"
echo ""
echo "Cluster status:"
kubectl get nodes -o wide
kubectl get ns | grep le-
