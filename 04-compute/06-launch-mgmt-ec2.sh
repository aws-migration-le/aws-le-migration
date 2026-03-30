#!/usr/bin/env bash
# ============================================================
# PHASE 4 — STEP 6: Launch Management+ITSM EC2 (EC2-B)
# m5.2xlarge, PUBLIC subnet AZ1 (no bastion needed)
# Runs: Harbor, ArgoCD, Keycloak, Vault, PostgreSQL, ITSM
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Launching Mgmt+ITSM EC2-B (m5.2xlarge, 8vCPU/32GB)"
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

# ─── ArgoCD CLI ──────────────────────────────────────────────
curl -fsSL -o /usr/local/bin/argocd \
  "https://github.com/argoproj/argo-cd/releases/download/v2.10.0/argocd-linux-amd64"
chmod +x /usr/local/bin/argocd

# ─── Format + mount secondary EBS volume ─────────────────────
while [ ! -b /dev/xvdf ]; do sleep 2; done
mkfs.ext4 /dev/xvdf
mkdir -p /data
mount /dev/xvdf /data
echo '/dev/xvdf /data ext4 defaults,nofail 0 2' >> /etc/fstab

# Create data directories for each service
mkdir -p /data/{postgresql,harbor,argocd,keycloak,vault,itsm}
chown -R 1000:1000 /data

# ─── Docker Compose file for management + ITSM stack ─────────
cat > /home/ubuntu/docker-compose-mgmt.yml <<'COMPOSE'
services:
  postgresql:
    image: postgres:16-alpine
    container_name: postgresql
    restart: unless-stopped
    ports:
      - "5432:5432"
    volumes:
      - /data/postgresql:/var/lib/postgresql/data
    environment:
      POSTGRES_PASSWORD: LinkedEye@DB2026
      POSTGRES_DB: postgres
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  harbor-core:
    image: goharbor/harbor-core:v2.10.0
    container_name: harbor-core
    restart: unless-stopped
    depends_on:
      postgresql:
        condition: service_healthy
    ports:
      - "8083:8080"
    volumes:
      - /data/harbor:/data
    environment:
      DATABASE_TYPE: postgresql
      POSTGRESQL_HOST: postgresql
      POSTGRESQL_PORT: 5432
      POSTGRESQL_USERNAME: postgres
      POSTGRESQL_PASSWORD: LinkedEye@DB2026
      POSTGRESQL_DATABASE: harbor_db

  harbor-registry:
    image: goharbor/registry-photon:v2.10.0
    container_name: harbor-registry
    restart: unless-stopped
    ports:
      - "5000:5000"
    volumes:
      - /data/harbor/registry:/storage

  argocd-server:
    image: quay.io/argoproj/argocd:v2.10.0
    container_name: argocd
    restart: unless-stopped
    command: argocd-server --insecure
    ports:
      - "8082:8080"
    volumes:
      - /data/argocd:/home/argocd

  keycloak:
    image: quay.io/keycloak/keycloak:26.0
    container_name: keycloak
    restart: unless-stopped
    command: start-dev
    depends_on:
      postgresql:
        condition: service_healthy
    ports:
      - "8081:8080"
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgresql:5432/keycloak_db
      KC_DB_USERNAME: postgres
      KC_DB_PASSWORD: LinkedEye@DB2026
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: LinkedEye@2026

  vault:
    image: hashicorp/vault:1.15
    container_name: vault
    restart: unless-stopped
    cap_add:
      - IPC_LOCK
    ports:
      - "8200:8200"
    volumes:
      - /data/vault:/vault/data
    environment:
      VAULT_ADDR: http://0.0.0.0:8200
      VAULT_API_ADDR: http://0.0.0.0:8200
    command: server -config=/vault/config/vault.hcl

  itsm:
    image: linkedeye/itsm:latest
    container_name: itsm
    restart: unless-stopped
    depends_on:
      postgresql:
        condition: service_healthy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /data/itsm:/app/data
    environment:
      DATABASE_URL: postgresql://postgres:LinkedEye@DB2026@postgresql:5432/itsm_db
COMPOSE

# ─── Vault config ────────────────────────────────────────────
mkdir -p /data/vault/config
cat > /data/vault/config/vault.hcl <<'VAULTCFG'
storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

ui = true
VAULTCFG

chown -R ubuntu:ubuntu /home/ubuntu/docker-compose-mgmt.yml

echo "Mgmt+ITSM EC2 user-data complete" >> /var/log/user-data.log
USEREOF
)

echo "[4.6] Launching Management+ITSM EC2-B (PUBLIC subnet)"
MGMT_EC2_ID=$(aws ec2 run-instances \
  --image-id "${AMI_ID}" \
  --instance-type "${MGMT_EC2_TYPE}" \
  --key-name "${KEY_PAIR_NAME}" \
  --subnet-id "${PUB_SUBNET_AZ1}" \
  --security-group-ids "${SG_MGMT_EC2}" \
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
    {Key=Name,Value=${PROJECT}-mgmt-itsm-ec2},
    {Key=Role,Value=mgmt-tools},
    {Key=Component,Value=Harbor-ArgoCD-Keycloak-Vault-ITSM},
    {Key=Project,Value=${TAG_PROJECT}},
    {Key=Environment,Value=${TAG_ENV}}
  ]" "ResourceType=volume,Tags=[
    {Key=Name,Value=${PROJECT}-mgmt-vol},
    {Key=Project,Value=${TAG_PROJECT}}
  ]" \
  --query 'Instances[0].InstanceId' --output text)

echo "    Mgmt EC2: ${MGMT_EC2_ID} — waiting for running state..."
aws ec2 wait instance-running --instance-ids "${MGMT_EC2_ID}"

MGMT_PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "${MGMT_EC2_ID}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

cat >> /tmp/le-network-ids.env <<EOF
export MGMT_EC2_ID="${MGMT_EC2_ID}"
export MGMT_PUBLIC_IP="${MGMT_PUBLIC_IP}"
EOF

echo ""
echo "[DONE] Management+ITSM EC2-B launched (PUBLIC subnet)"
echo "  Instance:   ${MGMT_EC2_ID}"
echo "  Public IP:  ${MGMT_PUBLIC_IP}"
echo "  Type:       ${MGMT_EC2_TYPE}"
echo "  Storage:    100 GB (OS) + 200 GB (service data at /data)"
echo "  Services:   PostgreSQL, Harbor, ArgoCD, Keycloak, Vault, ITSM"
echo ""
echo "  SSH directly:"
echo "    ssh ubuntu@${MGMT_PUBLIC_IP} -i ~/.ssh/${KEY_PAIR_NAME}.pem"
echo "  Then start services:"
echo "    docker compose -f docker-compose-mgmt.yml up -d"
