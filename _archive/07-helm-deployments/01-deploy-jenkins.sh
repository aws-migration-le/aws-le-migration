#!/usr/bin/env bash
# ============================================================
# PHASE 7 — Deploy Jenkins (CI/CD) in le-cicd namespace
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

echo "============================================================"
echo " Deploying Jenkins in namespace: le-cicd"
echo "============================================================"

# Add Helm repo
helm repo add jenkins https://charts.jenkins.io
helm repo update

# Deploy with production values
helm upgrade --install jenkins jenkins/jenkins \
  --namespace le-cicd \
  --create-namespace \
  --values "$(dirname "$0")/../helm-values/jenkins-values.yaml" \
  --set controller.jenkinsUrl="https://${JENKINS_DOMAIN}" \
  --wait --timeout 10m

echo ""
echo "[DONE] Jenkins deployed"
echo ""
echo "Get admin password:"
echo "  kubectl exec -n le-cicd -it svc/jenkins -c jenkins -- /bin/cat /run/secrets/additional/chart-admin-password"
echo ""
echo "  URL: https://${JENKINS_DOMAIN}"
