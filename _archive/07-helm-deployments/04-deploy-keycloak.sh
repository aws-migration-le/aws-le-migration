#!/usr/bin/env bash
# ============================================================
# PHASE 7 — Deploy Keycloak HA (SSO/OIDC) in le-security
# 2 replicas as per architecture spec
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

echo "============================================================"
echo " Deploying Keycloak HA (2 replicas) in namespace: le-security"
echo "============================================================"

helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm upgrade --install keycloak bitnami/keycloak \
  --namespace le-security \
  --values "$(dirname "$0")/../helm-values/keycloak-values.yaml" \
  --set auth.adminUser=admin \
  --set replicaCount=2 \
  --set ingress.hostname="${KEYCLOAK_DOMAIN}" \
  --wait --timeout 15m

echo ""
echo "[DONE] Keycloak deployed (2 replicas HA)"
echo ""
echo "  URL:  https://${KEYCLOAK_DOMAIN}"
echo "  User: admin"
echo ""
echo "Post-setup:"
echo "  1. Login and create realm: linkedeye"
echo "  2. Create clients: jenkins, argocd, harbor, vault"
echo "  3. Configure LDAP/AD federation if needed"
