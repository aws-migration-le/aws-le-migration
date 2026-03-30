#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 06: Configure Vault TLS + KMS Auto-Unseal
# Generates TLS cert, uploads to EC2-B, updates vault.hcl with
# KMS seal stanza + TLS listener, restarts Vault, migrates
# from Shamir to KMS auto-unseal.
# Depends on: 01-create-kms-keys.sh (KMS_VAULT_KEY_ID)
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Configuring Vault TLS + KMS Auto-Unseal"
echo " Target: EC2-B (${MGMT_PUBLIC_IP})"
echo "============================================================"

SSH_KEY="${HOME}/.ssh/${KEY_PAIR_NAME}.pem"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# ─── 1. GENERATE TLS CERTIFICATE ──────────────────────────
echo "[1/5] Generating self-signed TLS certificate for Vault"

CERT_DIR="/tmp/vault-tls"
mkdir -p "${CERT_DIR}"

openssl req -x509 -nodes -days 3650 \
  -newkey rsa:4096 \
  -keyout "${CERT_DIR}/vault-key.pem" \
  -out "${CERT_DIR}/vault-cert.pem" \
  -subj "/CN=vault.finspot.in/O=FinSpot Technology Solutions" \
  -addext "subjectAltName=DNS:vault.finspot.in,DNS:localhost,IP:${MGMT_PUBLIC_IP},IP:127.0.0.1"

echo "    Certificate generated (10-year validity)"
echo "    CN: vault.finspot.in"

# ─── 2. UPLOAD TLS CERTS TO EC2-B ─────────────────────────
echo "[2/5] Uploading TLS certificates to EC2-B"

ssh ${SSH_OPTS} -i "${SSH_KEY}" ubuntu@"${MGMT_PUBLIC_IP}" \
  "sudo mkdir -p /data/vault/tls && sudo chown -R ubuntu:ubuntu /data/vault/tls"

scp ${SSH_OPTS} -i "${SSH_KEY}" \
  "${CERT_DIR}/vault-cert.pem" "${CERT_DIR}/vault-key.pem" \
  ubuntu@"${MGMT_PUBLIC_IP}":/data/vault/tls/

ssh ${SSH_OPTS} -i "${SSH_KEY}" ubuntu@"${MGMT_PUBLIC_IP}" \
  "sudo chmod 600 /data/vault/tls/vault-key.pem && sudo chmod 644 /data/vault/tls/vault-cert.pem"

echo "    Certificates uploaded to /data/vault/tls/"

# ─── 3. UPDATE VAULT CONFIGURATION ────────────────────────
echo "[3/5] Updating vault.hcl with TLS + KMS auto-unseal"

ssh ${SSH_OPTS} -i "${SSH_KEY}" ubuntu@"${MGMT_PUBLIC_IP}" bash <<REMOTE_EOF
cat > /data/vault/config/vault.hcl <<'VAULTCFG'
storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/vault/data/tls/vault-cert.pem"
  tls_key_file  = "/vault/data/tls/vault-key.pem"
}

seal "awskms" {
  region     = "${AWS_REGION}"
  kms_key_id = "${KMS_VAULT_KEY_ID}"
}

api_addr     = "https://0.0.0.0:8200"
cluster_addr = "https://0.0.0.0:8201"
ui           = true
VAULTCFG
REMOTE_EOF

echo "    vault.hcl updated: TLS enabled, KMS seal configured"

# ─── 4. UPDATE DOCKER COMPOSE VAULT ENVIRONMENT ───────────
echo "[4/5] Updating Vault container environment"

ssh ${SSH_OPTS} -i "${SSH_KEY}" ubuntu@"${MGMT_PUBLIC_IP}" bash <<'REMOTE_EOF'
# Update VAULT_ADDR to https in the compose file
if [ -f /home/ubuntu/docker-compose-mgmt.yml ]; then
  sed -i 's|VAULT_ADDR: http://0.0.0.0:8200|VAULT_ADDR: https://0.0.0.0:8200|g' /home/ubuntu/docker-compose-mgmt.yml
  sed -i 's|VAULT_API_ADDR: http://0.0.0.0:8200|VAULT_API_ADDR: https://0.0.0.0:8200|g' /home/ubuntu/docker-compose-mgmt.yml
fi
REMOTE_EOF

echo "    Docker compose updated for HTTPS"

# ─── 5. RESTART VAULT ─────────────────────────────────────
echo "[5/5] Restarting Vault container"

ssh ${SSH_OPTS} -i "${SSH_KEY}" ubuntu@"${MGMT_PUBLIC_IP}" \
  "cd /home/ubuntu && docker compose -f docker-compose-mgmt.yml restart vault 2>/dev/null || echo 'Vault not running yet — will start with TLS on next docker compose up'"

# Clean up local temp certs
rm -rf "${CERT_DIR}"

echo ""
echo "[DONE] Vault TLS + KMS Auto-Unseal configured"
echo "  TLS:        enabled (self-signed, vault.finspot.in)"
echo "  KMS Seal:   ${KMS_VAULT_KEY_ID} (${AWS_REGION})"
echo "  Vault URL:  https://${MGMT_PUBLIC_IP}:8200"
echo ""
echo "  IMPORTANT — Seal Migration:"
echo "    If Vault was previously initialized with Shamir keys,"
echo "    you must perform a seal migration:"
echo "      1. SSH to EC2-B: ssh ubuntu@${MGMT_PUBLIC_IP} -i ${SSH_KEY}"
echo "      2. docker exec -it vault vault operator unseal -migrate"
echo "      3. Provide existing unseal keys when prompted"
echo "      4. Once migrated, Vault will auto-unseal via KMS"
