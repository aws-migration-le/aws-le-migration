#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 12: Deploy External Secrets Operator
# Installs ESO via Helm, creates ClusterSecretStore pointing
# to Vault (HTTPS), example ExternalSecret for le-workloads.
# Depends on: 06-configure-vault-tls-autounseal.sh (Vault TLS)
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Deploying External Secrets Operator"
echo " Vault: https://${MGMT_PUBLIC_IP}:8200"
echo "============================================================"

# ─── 1. ADD HELM REPO ─────────────────────────────────────
echo "[1/4] Adding external-secrets Helm repo"

helm repo add external-secrets \
  https://charts.external-secrets.io 2>/dev/null || true
helm repo update

echo "    Helm repo ready"

# ─── 2. INSTALL ESO ───────────────────────────────────────
echo "[2/4] Installing External Secrets Operator"

helm upgrade --install external-secrets \
  external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --set webhook.port=9443 \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=256Mi \
  --timeout 5m \
  --wait

echo "    ESO installed in namespace: external-secrets"

# ─── 3. CREATE VAULT TOKEN SECRET ─────────────────────────
echo "[3/4] Creating Vault auth secret (update token after Vault init)"

kubectl create namespace le-workloads 2>/dev/null || true

# Create placeholder secret for Vault token
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: vault-token
  namespace: external-secrets
  labels:
    app.kubernetes.io/part-of: linkedeye
type: Opaque
stringData:
  token: "hvs.PLACEHOLDER_UPDATE_AFTER_VAULT_INIT"
EOF

echo "    Vault token secret created (update with real token after Vault init)"

# ─── 4. CREATE CLUSTERSECRETSTORE + EXAMPLE ───────────────
echo "[4/4] Creating ClusterSecretStore and example ExternalSecret"

VAULT_URL="https://${MGMT_PUBLIC_IP}:8200"

kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: le-vault-store
  labels:
    app.kubernetes.io/part-of: linkedeye
spec:
  provider:
    vault:
      server: "${VAULT_URL}"
      path: "secret"
      version: "v2"
      caProvider:
        type: ConfigMap
        name: vault-ca
        namespace: external-secrets
        key: ca.crt
      auth:
        tokenSecretRef:
          name: vault-token
          namespace: external-secrets
          key: token
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: le-example-secret
  namespace: le-workloads
  labels:
    app.kubernetes.io/part-of: linkedeye
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: le-vault-store
    kind: ClusterSecretStore
  target:
    name: le-app-secrets
    creationPolicy: Owner
  data:
  - secretKey: db-password
    remoteRef:
      key: secret/le-shared-prod/database
      property: password
  - secretKey: api-key
    remoteRef:
      key: secret/le-shared-prod/api
      property: key
EOF

echo "    ClusterSecretStore: le-vault-store"
echo "    Example ExternalSecret: le-example-secret (le-workloads)"

echo ""
echo "[DONE] External Secrets Operator deployed"
echo "  ESO:         external-secrets namespace"
echo "  Vault URL:   ${VAULT_URL}"
echo "  Store:       le-vault-store (ClusterSecretStore)"
echo ""
echo "  IMPORTANT — After Vault is initialized:"
echo "    1. Create a Vault token with read policy for secret/*"
echo "    2. Update the token secret:"
echo "       kubectl -n external-secrets create secret generic vault-token \\"
echo "         --from-literal=token=<real-vault-token> --dry-run=client -o yaml | kubectl apply -f -"
echo "    3. Upload Vault CA cert as ConfigMap:"
echo "       kubectl -n external-secrets create configmap vault-ca \\"
echo "         --from-file=ca.crt=/path/to/vault-cert.pem"
