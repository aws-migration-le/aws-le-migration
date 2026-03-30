#!/usr/bin/env bash
# ============================================================
# PHASE 7 — Deploy HashiCorp Vault HA (3 Raft replicas)
# Path pattern: secret/le-{client}-prod/*  (from docs)
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

echo "============================================================"
echo " Deploying HashiCorp Vault HA (3 Raft replicas) in le-security"
echo "============================================================"

helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm upgrade --install vault hashicorp/vault \
  --namespace le-security \
  --values "$(dirname "$0")/../helm-values/vault-values.yaml" \
  --wait --timeout 10m

echo ""
echo "[INFO] Vault pods launched — must initialize and unseal"
echo ""

# Wait for pods
kubectl wait --for=condition=Ready pod/vault-0 -n le-security --timeout=120s || true

echo "[VAULT-INIT] Initializing Vault cluster"
kubectl exec -n le-security vault-0 -- vault operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json > /tmp/vault-init.json

echo "  CRITICAL: Vault keys saved to /tmp/vault-init.json"
echo "  Store these keys in a secure location IMMEDIATELY"
echo ""

# Extract unseal keys and root token
UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' /tmp/vault-init.json)
UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' /tmp/vault-init.json)
UNSEAL_KEY_3=$(jq -r '.unseal_keys_b64[2]' /tmp/vault-init.json)
ROOT_TOKEN=$(jq -r '.root_token' /tmp/vault-init.json)

echo "[VAULT-UNSEAL] Unsealing vault-0"
kubectl exec -n le-security vault-0 -- vault operator unseal "${UNSEAL_KEY_1}"
kubectl exec -n le-security vault-0 -- vault operator unseal "${UNSEAL_KEY_2}"
kubectl exec -n le-security vault-0 -- vault operator unseal "${UNSEAL_KEY_3}"

echo "[VAULT-UNSEAL] Joining and unsealing vault-1 (Raft)"
kubectl exec -n le-security vault-1 -- vault operator raft join http://vault-0.vault-internal:8200
kubectl exec -n le-security vault-1 -- vault operator unseal "${UNSEAL_KEY_1}"
kubectl exec -n le-security vault-1 -- vault operator unseal "${UNSEAL_KEY_2}"
kubectl exec -n le-security vault-1 -- vault operator unseal "${UNSEAL_KEY_3}"

echo "[VAULT-UNSEAL] Joining and unsealing vault-2 (Raft)"
kubectl exec -n le-security vault-2 -- vault operator raft join http://vault-0.vault-internal:8200
kubectl exec -n le-security vault-2 -- vault operator unseal "${UNSEAL_KEY_1}"
kubectl exec -n le-security vault-2 -- vault operator unseal "${UNSEAL_KEY_2}"
kubectl exec -n le-security vault-2 -- vault operator unseal "${UNSEAL_KEY_3}"

echo "[VAULT-SETUP] Enabling KV secrets engine"
kubectl exec -n le-security vault-0 -- \
  vault login "${ROOT_TOKEN}"
kubectl exec -n le-security vault-0 -- \
  vault secrets enable -path=secret kv-v2

echo ""
echo "[DONE] Vault HA ready (3 Raft replicas)"
echo "  Root token: saved in /tmp/vault-init.json"
echo "  URL: https://${VAULT_DOMAIN}"
echo ""
echo "  Secret path pattern: secret/le-{client}-prod/*"
echo "  Example: vault kv put secret/le-indmoney-prod/st2 api_key=xxx"
