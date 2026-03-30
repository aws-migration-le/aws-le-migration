#!/usr/bin/env bash
# ============================================================
# PHASE 7 — Deploy Harbor (Container Registry) in le-cicd
# Includes Trivy CVE scanning integration
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

echo "============================================================"
echo " Deploying Harbor in namespace: le-cicd"
echo "============================================================"

helm repo add harbor https://helm.goharbor.io
helm repo update

helm upgrade --install harbor harbor/harbor \
  --namespace le-cicd \
  --values "$(dirname "$0")/../helm-values/harbor-values.yaml" \
  --set expose.ingress.hosts.core="${HARBOR_DOMAIN}" \
  --set externalURL="https://${HARBOR_DOMAIN}" \
  --wait --timeout 15m

echo ""
echo "[DONE] Harbor deployed"
echo ""
echo "  URL:      https://${HARBOR_DOMAIN}"
echo "  User:     admin"
echo "  Password: Harbor12345 (change immediately!)"
echo ""
echo "Post-setup:"
echo "  1. Login to Harbor UI and change admin password"
echo "  2. Create project: finspot-images"
echo "  3. Enable Trivy scanner: Administration > Interrogation Services"
echo "  4. Set scan on push: project settings"
