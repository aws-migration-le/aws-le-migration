#!/usr/bin/env bash
# ============================================================
# PHASE 4 — STEP 2: Launch Bastion Host (SSH Jump Server)
# Public subnet, t3.medium
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Launching Bastion Host (t3.medium)"
echo "============================================================"

USERDATA=$(cat <<'EOF'
#!/bin/bash
apt-get update -y
apt-get install -y curl wget vim htop net-tools
# Install kubectl for cluster management from bastion
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && mv kubectl /usr/local/bin/
# Install AWS CLI (already installed, but ensure latest)
apt-get install -y awscli
echo "Bastion ready" >> /var/log/user-data.log
EOF
)

BASTION_ID=$(aws ec2 run-instances \
  --image-id "${AMI_ID}" \
  --instance-type "${BASTION_INSTANCE_TYPE}" \
  --key-name "${KEY_PAIR_NAME}" \
  --subnet-id "${PUB_SUBNET_AZ1}" \
  --security-group-ids "${SG_BASTION}" \
  --iam-instance-profile Name="${PROJECT}-bastion-profile" \
  --user-data "${USERDATA}" \
  --block-device-mappings '[{
    "DeviceName":"/dev/sda1",
    "Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}
  }]' \
  --tag-specifications "ResourceType=instance,Tags=[
    {Key=Name,Value=${PROJECT}-bastion},
    {Key=Role,Value=bastion},
    {Key=Project,Value=${TAG_PROJECT}},
    {Key=Environment,Value=${TAG_ENV}}
  ]" \
  --query 'Instances[0].InstanceId' --output text)

echo "    Bastion launched: ${BASTION_ID}"
echo "    Waiting for running state..."
aws ec2 wait instance-running --instance-ids "${BASTION_ID}"

BASTION_PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "${BASTION_ID}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo "    Public IP: ${BASTION_PUBLIC_IP}"

cat >> /tmp/le-network-ids.env <<EOF
export BASTION_ID="${BASTION_ID}"
export BASTION_PUBLIC_IP="${BASTION_PUBLIC_IP}"
EOF

echo ""
echo "[DONE] Bastion ready"
echo "  SSH: ssh -i ${KEY_FILE} ubuntu@${BASTION_PUBLIC_IP}"
