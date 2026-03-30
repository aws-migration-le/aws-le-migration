#!/usr/bin/env bash
# ============================================================
# PHASE 4 — STEP 5: Launch Jenkins EC2 (EC2-A)
# m5.xlarge, PUBLIC subnet AZ1 (no bastion needed)
# User-data: Docker CE, docker-compose, aws-cli, kubectl, helm
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Launching Jenkins EC2-A (m5.xlarge, 4vCPU/16GB)"
echo " Public subnet — direct SSH access from office"
echo "============================================================"

USERDATA=$(cat <<'USEREOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# ─── System prep ─────────────────────────────────────────────
apt-get update -y && apt-get upgrade -y
apt-get install -y curl wget vim htop net-tools jq unzip nfs-common

# ─── Docker CE ───────────────────────────────────────────────
apt-get install -y ca-certificates gnupg lsb-release
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > \
  /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker && systemctl start docker
usermod -aG docker ubuntu

# ─── AWS CLI v2 ──────────────────────────────────────────────
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

# ─── kubectl ─────────────────────────────────────────────────
curl -fsSL "https://dl.k8s.io/release/v1.29.0/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl

# ─── Helm ────────────────────────────────────────────────────
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ─── Format + mount secondary EBS volume ─────────────────────
while [ ! -b /dev/xvdf ]; do sleep 2; done
mkfs.ext4 /dev/xvdf
mkdir -p /data/jenkins
mount /dev/xvdf /data/jenkins
echo '/dev/xvdf /data/jenkins ext4 defaults,nofail 0 2' >> /etc/fstab
chown 1000:1000 /data/jenkins

echo "Jenkins EC2 user-data complete" >> /var/log/user-data.log
USEREOF
)

echo "[4.5] Launching Jenkins EC2-A (PUBLIC subnet)"
JENKINS_EC2_ID=$(aws ec2 run-instances \
  --image-id "${AMI_ID}" \
  --instance-type "${JENKINS_EC2_TYPE}" \
  --key-name "${KEY_PAIR_NAME}" \
  --subnet-id "${PUB_SUBNET_AZ1}" \
  --security-group-ids "${SG_JENKINS_EC2}" \
  --associate-public-ip-address \
  --iam-instance-profile Name="${PROJECT}-mgmt-ec2-profile" \
  --user-data "${USERDATA}" \
  --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled \
  --block-device-mappings '[
    {"DeviceName":"/dev/sda1",
     "Ebs":{"VolumeSize":100,"VolumeType":"gp3","Iops":3000,"DeleteOnTermination":false}},
    {"DeviceName":"/dev/xvdf",
     "Ebs":{"VolumeSize":200,"VolumeType":"gp3","Iops":3000,"DeleteOnTermination":false}}
  ]' \
  --tag-specifications "ResourceType=instance,Tags=[
    {Key=Name,Value=${PROJECT}-jenkins-ec2},
    {Key=Role,Value=jenkins},
    {Key=Component,Value=CI-CD},
    {Key=Project,Value=${TAG_PROJECT}},
    {Key=Environment,Value=${TAG_ENV}}
  ]" "ResourceType=volume,Tags=[
    {Key=Name,Value=${PROJECT}-jenkins-vol},
    {Key=Project,Value=${TAG_PROJECT}}
  ]" \
  --query 'Instances[0].InstanceId' --output text)

echo "    Jenkins EC2: ${JENKINS_EC2_ID} — waiting for running state..."
aws ec2 wait instance-running --instance-ids "${JENKINS_EC2_ID}"

JENKINS_PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "${JENKINS_EC2_ID}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

cat >> /tmp/le-network-ids.env <<EOF
export JENKINS_EC2_ID="${JENKINS_EC2_ID}"
export JENKINS_PUBLIC_IP="${JENKINS_PUBLIC_IP}"
EOF

echo ""
echo "[DONE] Jenkins EC2-A launched (PUBLIC subnet)"
echo "  Instance:   ${JENKINS_EC2_ID}"
echo "  Public IP:  ${JENKINS_PUBLIC_IP}"
echo "  Type:       ${JENKINS_EC2_TYPE}"
echo "  Storage:    100 GB (OS) + 200 GB (Jenkins data at /data/jenkins)"
echo ""
echo "  SSH directly:"
echo "    ssh ubuntu@${JENKINS_PUBLIC_IP} -i ~/.ssh/${KEY_PAIR_NAME}.pem"
