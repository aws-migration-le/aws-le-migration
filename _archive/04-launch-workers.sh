#!/usr/bin/env bash
# ============================================================
# PHASE 4 — STEP 4: Launch K8s Worker Node (1x m5.4xlarge)
# Worker-1: 10.15.10.20 (AZ1) — all workloads: le-cicd, le-security
# NOTE: Single worker is sufficient for shared tools deployment
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

USERDATA=$(cat <<'USEREOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get upgrade -y
apt-get install -y curl wget vim htop net-tools nfs-common
swapoff -a
sed -i '/swap/d' /etc/fstab
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay && modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd && systemctl enable containerd
apt-get install -y apt-transport-https ca-certificates gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet=1.29.* kubeadm=1.29.* kubectl=1.29.*
apt-mark hold kubelet kubeadm kubectl
echo "Worker ready" >> /var/log/user-data.log
USEREOF
)

# ─── WORKER 1 (AZ1) ──────────────────────────────────────────
echo "[4.4] Launching Worker Node 1 (AZ1, 10.15.10.20) — m5.4xlarge 16vCPU/64GB"
WORKER1_ID=$(aws ec2 run-instances \
  --image-id "${AMI_ID}" \
  --instance-type "${WORKER_INSTANCE_TYPE}" \
  --key-name "${KEY_PAIR_NAME}" \
  --subnet-id "${PRIV_SUBNET_AZ1}" \
  --security-group-ids "${SG_K8S_WORKER}" \
  --private-ip-address "10.15.10.20" \
  --iam-instance-profile Name="${PROJECT}-k8s-worker-profile" \
  --user-data "${USERDATA}" \
  --block-device-mappings '[{
    "DeviceName":"/dev/sda1",
    "Ebs":{"VolumeSize":200,"VolumeType":"gp3","Iops":3000,"DeleteOnTermination":false}
  }]' \
  --tag-specifications "ResourceType=instance,Tags=[
    {Key=Name,Value=${PROJECT}-k8s-worker-1},
    {Key=Role,Value=k8s-worker},
    {Key=WorkloadGroup,Value=all-shared-tools},
    {Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned},
    {Key=Project,Value=${TAG_PROJECT}},
    {Key=Environment,Value=${TAG_ENV}}
  ]" \
  --query 'Instances[0].InstanceId' --output text)

echo "    Waiting for worker to be running..."
aws ec2 wait instance-running --instance-ids "${WORKER1_ID}"

cat >> /tmp/le-network-ids.env <<EOF
export WORKER1_ID="${WORKER1_ID}"
export WORKER1_IP="10.15.10.20"
EOF

echo ""
echo "[DONE] Worker Node launched"
echo "  Worker1: ${WORKER1_ID}  (10.15.10.20 AZ1)"
echo ""
echo "  Hosts Jenkins + ArgoCD + Harbor + Keycloak + Vault"
echo "  Add worker-2 later when scaling per-client workloads"
