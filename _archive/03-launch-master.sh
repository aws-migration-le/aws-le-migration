#!/usr/bin/env bash
# ============================================================
# PHASE 4 — STEP 3: Launch K8s Master Node (m5.2xlarge)
# Private subnet AZ1, static IP 10.15.10.10
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Launching K8s Master Node (m5.2xlarge, 8vCPU/32GB)"
echo "============================================================"

USERDATA=$(cat <<'USEREOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# ─── System prep ─────────────────────────────────────────────
apt-get update -y && apt-get upgrade -y
apt-get install -y curl wget vim htop net-tools nfs-common

# Disable swap (K8s requirement)
swapoff -a
sed -i '/swap/d' /etc/fstab

# Load required kernel modules
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# Sysctl settings for K8s
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# ─── Install containerd ──────────────────────────────────────
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd && systemctl enable containerd

# ─── Install kubeadm, kubelet, kubectl ───────────────────────
apt-get install -y apt-transport-https ca-certificates gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet=1.29.* kubeadm=1.29.* kubectl=1.29.*
apt-mark hold kubelet kubeadm kubectl

echo "K8s packages installed" >> /var/log/user-data.log
USEREOF
)

echo "[4.3] Launching K8s master node"
MASTER_ID=$(aws ec2 run-instances \
  --image-id "${AMI_ID}" \
  --instance-type "${MASTER_INSTANCE_TYPE}" \
  --key-name "${KEY_PAIR_NAME}" \
  --subnet-id "${PRIV_SUBNET_AZ1}" \
  --security-group-ids "${SG_K8S_MASTER}" \
  --private-ip-address "${K8S_MASTER_PRIVATE_IP}" \
  --iam-instance-profile Name="${PROJECT}-k8s-master-profile" \
  --user-data "${USERDATA}" \
  --block-device-mappings '[{
    "DeviceName":"/dev/sda1",
    "Ebs":{"VolumeSize":100,"VolumeType":"gp3","Iops":3000,"DeleteOnTermination":false}
  }]' \
  --tag-specifications "ResourceType=instance,Tags=[
    {Key=Name,Value=${PROJECT}-k8s-master},
    {Key=Role,Value=k8s-master},
    {Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned},
    {Key=Project,Value=${TAG_PROJECT}},
    {Key=Environment,Value=${TAG_ENV}}
  ]" \
  --query 'Instances[0].InstanceId' --output text)

echo "    Master: ${MASTER_ID} — waiting for running state..."
aws ec2 wait instance-running --instance-ids "${MASTER_ID}"

cat >> /tmp/le-network-ids.env <<EOF
export MASTER_ID="${MASTER_ID}"
export K8S_MASTER_PRIVATE_IP="${K8S_MASTER_PRIVATE_IP}"
EOF

echo ""
echo "[DONE] K8s Master launched"
echo "  Instance:   ${MASTER_ID}"
echo "  Private IP: ${K8S_MASTER_PRIVATE_IP}"
echo ""
echo "  NEXT: Wait ~3 minutes for user-data to finish, then run:"
echo "    ssh -J ubuntu@${BASTION_PUBLIC_IP} ubuntu@${K8S_MASTER_PRIVATE_IP} -i ${KEY_FILE}"
echo "    sudo bash /tmp/init-master.sh  (from 06-kubernetes/01-install-k8s-master.sh)"
