#!/usr/bin/env bash
# ============================================================
# PHASE 7 — Deploy ArgoCD (GitOps) in le-cicd namespace
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

echo "============================================================"
echo " Deploying ArgoCD in namespace: le-cicd"
echo "============================================================"

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace le-cicd \
  --values "$(dirname "$0")/../helm-values/argocd-values.yaml" \
  --set global.domain="${ARGOCD_DOMAIN}" \
  --wait --timeout 10m

echo ""
echo "[DONE] ArgoCD deployed"
echo ""
echo "Get initial admin password:"
echo "  kubectl -n le-cicd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "  URL: https://${ARGOCD_DOMAIN}"
